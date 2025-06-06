# ===----------------------------------------------------------------------=== #
# Copyright (c) 2025, Modular Inc. All rights reserved.
#
# Licensed under the Apache License v2.0 with LLVM Exceptions:
# https://llvm.org/LICENSE.txt
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ===----------------------------------------------------------------------=== #

from collections import Optional
from collections.string.string_slice import get_static_string
from os import abort
from sys.ffi import c_int
from sys.info import sizeof

from memory import UnsafePointer
from python import PythonObject, TypedPythonObject
from python.python_object import PyFunctionRaising, PyFunction
from python._cpython import (
    Py_TPFLAGS_DEFAULT,
    PyCFunction,
    PyMethodDef,
    PyObject,
    PyObjectPtr,
    PyType_Slot,
    PyType_Spec,
    destructor,
    newfunc,
)


trait ConvertibleFromPython(CollectionElement):
    """Denotes a type that can attempt construction from a read-only Python
    object.
    """

    @staticmethod
    fn try_from_python(obj: PythonObject) raises -> Self:
        """Attempt to construct an instance of this object from a read-only
        Python value.

        Args:
            obj: The Python object to convert from.

        Raises:
            If conversion was not successful.
        """
        ...


# ===-----------------------------------------------------------------------===#
# Mojo Object
# ===-----------------------------------------------------------------------===#

# Must be ABI compatible with `initproc`
alias Typed_initproc = fn (
    PyObjectPtr,
    TypedPythonObject["Tuple"],
    # Will be NULL if no keyword arguments were passed.
    PyObjectPtr,
) -> c_int


trait Pythonable(Defaultable, Representable):
    """Represents a Mojo type that can be used from Python."""

    pass


struct PyMojoObject[T: AnyType]:
    """Storage backing a PyObject* wrapping a Mojo value."""

    var ob_base: PyObject
    var mojo_value: T


fn python_type_object[
    T: Pythonable
](
    type_name: StaticString,
    owned methods: List[PyMethodDef] = List[PyMethodDef](),
) raises -> TypedPythonObject["Type"]:
    """Construct a Python 'type' describing PyMojoObject[T].

    Parameters:
        T: The mojo type to wrap.

    Args:
        type_name: The name of the Mojo type.
        methods: The methods to add to the type.
    """

    var cpython = Python().cpython()

    var slots = List[PyType_Slot](
        # All wrapped Mojo types are allocated generically.
        PyType_Slot.tp_new(
            cpython.lib.get_function[newfunc]("PyType_GenericNew")
        ),
        PyType_Slot.tp_init(empty_tp_init_wrapper[T]),
        PyType_Slot.tp_dealloc(tp_dealloc_wrapper[T]),
        PyType_Slot.tp_repr(tp_repr_wrapper[T]),
    )

    if methods:
        # FIXME: Avoid leaking the methods data pointer in this way.
        slots.append(PyType_Slot.tp_methods(methods.steal_data()))

    # Zeroed item terminator
    slots.append(PyType_Slot.null())

    var type_spec = PyType_Spec(
        # FIXME(MOCO-1306): This should be `T.__name__`.
        type_name.unsafe_ptr().bitcast[sys.ffi.c_char](),
        sizeof[PyMojoObject[T]](),
        0,
        Py_TPFLAGS_DEFAULT,
        # Note: This pointer is only "read-only" by PyType_FromSpec.
        slots.unsafe_ptr(),
    )

    # Construct a Python 'type' object from our type spec.
    var type_obj = cpython.PyType_FromSpec(UnsafePointer(to=type_spec))

    if type_obj.is_null():
        Python.throw_python_exception_if_error_state(cpython)
        return abort[TypedPythonObject["Type"]](
            "expected to raise after getting NULL type object"
        )

    return TypedPythonObject["Type"](
        unsafe_unchecked_from=PythonObject(type_obj)
    )


# Impedance match between:
#
#   Mojo:   fn(UnsafePointer[T]) -> None
#   Python: fn(PyObjectPtr, PyObjectPtr, PyObjectPtr)
#
# The latter is the C function signature that the CPython API expects a
# PyObject initializer function to have. The former is an unsafe form of the
# `fn(mut self)` signature that Mojo types with default constructors provide.
#
# To support CPython calling a Mojo types default constructor, we need to
# provide a wrapper function (around the Mojo constructor) that has the
# signature the C API expects.
#
# This function creates that wrapper function, and returns a pointer pointer to
# it.
fn empty_tp_init_wrapper[
    T: Pythonable
](
    py_self: PyObjectPtr,
    args: TypedPythonObject["Tuple"],
    keyword_args: PyObjectPtr,
) -> c_int:
    """Python-compatible wrapper around a Mojo initializer function.

    Parameters:
        T: The wrapped Mojo type.
    """

    var cpython = Python().cpython()

    try:
        if len(args) != 0 or keyword_args != PyObjectPtr():
            raise "unexpected arguments passed to default initializer function of wrapped Mojo type"

        var obj_ptr: UnsafePointer[T] = py_self.unchecked_cast_to_mojo_value[
            T
        ]()

        # ------------------------------------------------
        # Call the user-provided initialization function.
        # ------------------------------------------------

        # TODO(MSTDL-950): Avoid forming ref through uninit pointee.
        obj_ptr[] = T()

        return 0
    except e:
        # TODO(MSTDL-933): Add custom 'MojoError' type, and raise it here.
        var error_type = cpython.get_error_global("PyExc_ValueError")

        cpython.PyErr_SetString(
            error_type,
            e.unsafe_cstr_ptr(),
        )

        return -1


fn tp_dealloc_wrapper[T: Pythonable](py_self: PyObjectPtr):
    var self_ptr: UnsafePointer[T] = py_self.unchecked_cast_to_mojo_value[T]()

    # TODO(MSTDL-633):
    #   Is this always safe? Wrap in GIL, because this could
    #   evaluate arbitrary code?
    # Destroy this `Person` instance.
    self_ptr.destroy_pointee()


fn tp_repr_wrapper[T: Pythonable](py_self: PyObjectPtr) -> PyObjectPtr:
    var self_ptr: UnsafePointer[T] = py_self.unchecked_cast_to_mojo_value[T]()

    var repr_str: String = repr(self_ptr[])

    return PythonObject(string=repr_str).steal_data()


# ===-----------------------------------------------------------------------===#
# Builders
# ===-----------------------------------------------------------------------===#


struct PythonModuleBuilder:
    """API for declaring and creating Python bindings for a module."""

    var module: PythonModule
    var functions: List[PyMethodDef]

    fn __init__(out self, name: StaticString) raises:
        """Construct a Python module builder with the given module name.

        Args:
            name: The name of the module.

        Raises:
            If the module creation fails.
        """
        self = Self(PythonModule(name))

    fn __init__(out self, module: PythonModule):
        """Construct a Python module builder with the given module.

        Args:
            module: The module to build.
        """
        self.module = module
        self.functions = List[PyMethodDef]()

    fn def_py_c_function(
        mut self: Self,
        func: PyCFunction,
        func_name: StaticString,
        docstring: StaticString = StaticString(),
    ):
        """Declare a binding for a function with PyObjectPtr signature in the
        module.

        Args:
            func: The function to declare a binding for.
            func_name: The name with which the function will be exposed in the
                module.
            docstring: The docstring for the function in the module.
        """

        self.functions.append(PyMethodDef.function(func, func_name, docstring))

    fn def_py_function[
        func: PyFunction
    ](
        mut self: Self,
        func_name: StaticString,
        docstring: StaticString = StaticString(),
    ):
        """Declare a binding for a function with PyObject signature in the
        module.

        Parameters:
            func: The function to declare a binding for.

        Args:
            func_name: The name with which the function will be exposed in the
                module.
            docstring: The docstring for the function in the module.
        """

        self.def_py_c_function(
            py_c_function_wrapper[func], func_name, docstring
        )

    fn def_py_function[
        func: PyFunctionRaising
    ](
        mut self: Self,
        func_name: StaticString,
        docstring: StaticString = StaticString(),
    ):
        """Declare a binding for a function with PyObject signature in the
        module.

        Parameters:
            func: The function to declare a binding for.

        Args:
            func_name: The name with which the function will be exposed in the
                module.
            docstring: The docstring for the function in the module.
        """

        self.def_py_c_function(
            py_c_function_wrapper[func], func_name, docstring
        )

    fn finalize(mut self) raises -> PythonModule:
        """Finalize the module builder, creating the module object.

        All functions added to the builder will be built and exposed in the
        module.

        Raises:
            If the module creation fails or if we fail to add any of the
            declared functions to the module.
        """

        Python.add_functions(self.module, self.functions)
        self.functions.clear()

        return self.module


struct PythonTypeBuilder[T: Pythonable]:
    """A builder for a Python type binding.

    This builder is used to declare method bindings for a Python type, and then
    create the type binding.
    """

    var type_name: StaticString
    var methods: List[PyMethodDef]

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    fn __init__(out self, type_name: StaticString):
        """Construct a new builder for a Python type binding.

        Args:
            type_name: The name the type will be exposed as in the module.
        """
        self.type_name = type_name
        self.methods = List[PyMethodDef]()

    fn __copyinit__(out self, other: Self):
        """Copy an instance of this builder.

        Args:
            other: The builder to copy from.
        """
        self.type_name = other.type_name
        self.methods = other.methods

    fn __moveinit__(out self, owned other: Self):
        """Move an instance of this builder.

        Args:
            other: The builder to move from.
        """
        self.type_name = other.type_name
        self.methods = other.methods^

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    fn def_py_c_method(
        owned self,
        method: PyCFunction,
        method_name: StaticString,
        docstring: StaticString = StaticString(),
    ) -> Self:
        """Declare a binding for a method with PyObjectPtr signature for the
        type.

        Args:
            method: The method to declare a binding for.
            method_name: The name with which the method will be exposed on the
                type.
            docstring: The docstring for the method of the type.

        Returns:
            The builder with the method binding declared.
        """
        self.methods.append(
            PyMethodDef.function(method, method_name, docstring)
        )
        return self^

    fn finalize(owned self, module: PythonModule) raises:
        """Finalize the builder, creating the type binding with the registered
        methods.

        Raises:
            If we fail to add the type to the module.
        """
        self.methods.append(PyMethodDef())  # Zeroed item as terminator
        var type_obj = python_type_object[T](self.type_name, self.methods)
        Python.add_object(module, self.type_name, type_obj)


# ===-----------------------------------------------------------------------===#
# PyCFunction Wrappers
# ===-----------------------------------------------------------------------===#


fn py_c_function_wrapper[
    user_func: PyFunction
](py_self_ptr: PyObjectPtr, args_ptr: PyObjectPtr) -> PyObjectPtr:
    """The instantiated type of this generic function is a `PyCFunction`,
    suitable for being called from Python.
    """

    #   > When a C function is called from Python, it borrows references to its
    #   > arguments from the caller. The caller owns a reference to the object,
    #   > so the read-only reference’s lifetime is guaranteed until the function
    #   > returns. Only when such a read-only reference must be stored or passed
    #   > on, it must be turned into an owned reference by calling Py_INCREF().
    #   >
    #   >  -- https://docs.python.org/3/extending/extending.html#ownership-rules

    # SAFETY:
    #   Here we illegally (but carefully) construct _owned_ `PythonObject`
    #   values from the read-only object reference arguments. We are careful
    #   down below to prevent the destructor for these objects from running
    #   so that we do not illegally decrement the reference count of these
    #   objects we do not own.
    #
    #   This is valid to do, because these are passed using the `read-only`
    #   argument convention to `user_func`, so logically they are treated
    #   as Python read-only references.
    var py_self = PythonObject(py_self_ptr)
    var args = TypedPythonObject["Tuple"](
        unsafe_unchecked_from=PythonObject(args_ptr)
    )

    # SAFETY:
    #   Call the user provided function, and take ownership of the
    #   PyObjectPtr of the returned PythonObject.
    var result = user_func(py_self, args).steal_data()

    # Do not destroy the provided PyObjectPtr arguments, since they
    # actually have ownership of the underlying object.
    __disable_del py_self

    # SAFETY:
    #   Prevent `args` AND `args._obj` from being destroyed, since we don't
    #   own them.
    var _obj = args._obj^
    __disable_del args
    __disable_del _obj
    return result


# Wrap a `raises` function
fn py_c_function_wrapper[
    user_func: PyFunctionRaising
](py_self_ptr: PyObjectPtr, py_args_ptr: PyObjectPtr) -> PyObjectPtr:
    fn wrapper(
        py_self: PythonObject, args: TypedPythonObject["Tuple"]
    ) -> PythonObject:
        var cpython = Python().cpython()

        var state = cpython.PyGILState_Ensure()

        try:
            var result = user_func(py_self, args)
            return result
        except e:
            # TODO(MSTDL-933): Add custom 'MojoError' type, and raise it here.
            var error_type = cpython.get_error_global("PyExc_Exception")

            cpython.PyErr_SetString(
                error_type,
                e.unsafe_cstr_ptr(),
            )

            # Return a NULL `PyObject*`.
            return PythonObject(PyObjectPtr())
        finally:
            cpython.PyGILState_Release(state)

    # TODO:
    #   Does this lead to multiple levels of indirect function calls for
    #   `raises` functions? Could we fix that by marking `wrapper` here as
    #   `@always_inline`?
    # Call the non-`raises` overload of `py_c_function_wrapper`.
    return py_c_function_wrapper[wrapper](py_self_ptr, py_args_ptr)


fn check_arguments_arity(
    func_name: StringSlice,
    arity: Int,
    args: TypedPythonObject["Tuple"],
) raises:
    """Raise an error if the provided argument count does not match the expected
    function arity.

    If this function returns normally (without raising), then the argument
    count is exactly equal to the expected arity.
    """

    var arg_count = len(args)

    # The error messages raised below are intended to be similar to the
    # equivalent errors in Python.
    if arg_count != arity:
        if arg_count < arity:
            var missing_arg_count = arity - arg_count

            raise Error(
                String.format(
                    "TypeError: {}() missing {} required positional {}",
                    func_name,
                    missing_arg_count,
                    _pluralize(missing_arg_count, "argument", "arguments"),
                )
            )
        else:
            raise Error(
                String.format(
                    "TypeError: {}() takes {} positional {} but {} were given",
                    func_name,
                    arity,
                    _pluralize(arity, "argument", "arguments"),
                    arg_count,
                )
            )


fn check_argument_type[
    T: AnyType
](
    func_name: StaticString,
    type_name_id: StaticString,
    obj: PythonObject,
) raises -> UnsafePointer[T]:
    """Raise an error if the provided Python object does not contain a wrapped
    instance of the Mojo `T` type.
    """

    var opt: Optional[UnsafePointer[T]] = obj.py_object.try_cast_to_mojo_value[
        T
    ](type_name_id)

    if not opt:
        raise Error(
            String.format(
                "TypeError: {}() expected Mojo '{}' type argument, got '{}'",
                func_name,
                type_name_id,
                obj._get_type_name(),
            )
        )

    # SAFETY: We just validated that this Optional is not empty.
    return opt.unsafe_take()


fn _pluralize(
    count: Int,
    singular: StaticString,
    plural: StaticString,
) -> StaticString:
    if count == 1:
        return singular
    else:
        return plural
