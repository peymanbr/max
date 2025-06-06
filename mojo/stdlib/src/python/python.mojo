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
"""Implements Python interoperability.

You can import these APIs from the `python` package. For example:

```mojo
from python import Python
```
"""

from collections import Dict
from os import abort, getenv
from sys import external_call, sizeof
from sys.ffi import _Global

from memory import UnsafePointer

from ._cpython import (
    CPython,
    Py_eval_input,
    Py_file_input,
    Py_ssize_t,
    PyMethodDef,
)
from .python_object import PythonObject, TypedPythonObject, PythonModule

alias _PYTHON_GLOBAL = _Global["Python", _PythonGlobal, _init_python_global]


fn _init_python_global() -> _PythonGlobal:
    return _PythonGlobal()


struct _PythonGlobal(Movable):
    var cpython: CPython

    fn __init__(out self):
        self.cpython = CPython()

    fn __moveinit__(out self, owned other: Self):
        self.cpython = other.cpython^

    fn __del__(owned self):
        CPython.destroy(self.cpython)


@always_inline
fn _get_global_python_itf() -> _PythonInterfaceImpl:
    var ptr = _PYTHON_GLOBAL.get_or_create_ptr()
    return _PythonInterfaceImpl(ptr.bitcast[CPython]())


struct _PythonInterfaceImpl:
    var _cpython: UnsafePointer[CPython]

    @implicit
    fn __init__(out self, cpython: UnsafePointer[CPython]):
        self._cpython = cpython

    fn __copyinit__(out self, existing: Self):
        self._cpython = existing._cpython

    fn cpython(self) -> CPython:
        return self._cpython[]


struct Python:
    """Provides methods that help you use Python code in Mojo."""

    var _impl: _PythonInterfaceImpl
    """The underlying implementation of Mojo's Python interface."""

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    fn __init__(out self):
        """Default constructor."""
        self._impl = _get_global_python_itf()

    fn __copyinit__(out self, existing: Self):
        """Copy constructor.

        Args:
            existing: The existing instance to copy from.
        """
        self._impl = existing._impl

    @always_inline
    fn cpython(self) -> ref [StaticConstantOrigin] CPython:
        """Handle to the low-level C API of the CPython interpreter present in
        the current process.

        Returns:
            Handle to the CPython interpreter instance in the current process.
        """
        return self._cpython_ptr()[]

    @always_inline
    fn _cpython_ptr(self) -> Pointer[CPython, StaticConstantOrigin]:
        return Pointer[CPython, StaticConstantOrigin](to=self._impl._cpython[])

    fn eval(self, code: StringSlice) -> Bool:
        """Executes the given Python code.

        Args:
            code: The python code to execute.

        Returns:
            `True` if the code executed successfully or `False` if the code
            raised an exception.
        """
        var cpython = self.cpython()
        return cpython.PyRun_SimpleString(code)

    @staticmethod
    fn evaluate(
        expr: StringSlice,
        file: Bool = False,
        name: StringSlice[StaticConstantOrigin] = "__main__",
    ) raises -> PythonObject:
        """Executes the given Python code.

        Args:
            expr: The Python expression to evaluate.
            file: Evaluate as a file and return the module.
            name: The name of the module (most relevant if `file` is True).

        Returns:
            `PythonObject` containing the result of the evaluation.
        """
        var cpython = Self().cpython()
        # PyImport_AddModule returns a read-only reference.
        var module = PythonObject.from_borrowed_ptr(
            cpython.PyImport_AddModule(name)
        )
        var dict_obj = PythonObject.from_borrowed_ptr(
            cpython.PyModule_GetDict(module.py_object)
        )
        if file:
            # We compile the code as provided and execute in the module
            # context. Note that this may be an existing module if the provided
            # module name is not unique. The name here is used only for this
            # code object, not the module itself.
            #
            # The Py_file_input is the code passed to the parsed to indicate
            # the initial state: this is essentially whether it is expecting
            # to compile an expression, a file or statements (e.g. repl).
            var code = PythonObject(
                cpython.Py_CompileString(expr, "<evaluate>", Py_file_input)
            )
            # For this evaluation, we pass the dictionary both as the globals
            # and the locals. This is because the globals is defined as the
            # dictionary for the module scope, and locals is defined as the
            # dictionary for the *current* scope. Since we are executing at
            # the module scope for this eval, they should be the same object.
            var result = PythonObject(
                cpython.PyEval_EvalCode(
                    code.py_object, dict_obj.py_object, dict_obj.py_object
                )
            )
            Python.throw_python_exception_if_error_state(cpython)
            _ = code^
            _ = result^
            return module
        else:
            # We use the result of evaluating the expression directly, and allow
            # all the globals/locals to be discarded. See above re: why the same
            # dictionary is being used here for both globals and locals.
            var result = cpython.PyRun_String(
                expr, dict_obj.py_object, dict_obj.py_object, Py_eval_input
            )
            # We no longer need module and dictionary, release them.
            Python.throw_python_exception_if_error_state(cpython)
            return PythonObject(result)

    @staticmethod
    fn add_to_path(dir_path: StringSlice) raises:
        """Adds a directory to the Python path.

        This might be necessary to import a Python module via `import_module()`.
        For example:

        ```mojo
        from python import Python

        # Specify path to `mypython.py` module
        Python.add_to_path("path/to/module")
        var mypython = Python.import_module("mypython")

        var c = mypython.my_algorithm(2, 3)
        ```

        Args:
            dir_path: The path to a Python module you want to import.
        """
        var sys = Python.import_module("sys")
        var directory: PythonObject = dir_path
        _ = sys.path.append(directory)

    # ===-------------------------------------------------------------------===#
    # PythonObject "Module" Operations
    # ===-------------------------------------------------------------------===#

    # TODO(MSTDL-880): Change this to return `PythonModule`
    @staticmethod
    fn import_module(module: StringSlice) raises -> PythonObject:
        """Imports a Python module.

        This provides you with a module object you can use just like you would
        in Python. For example:

        ```mojo
        from python import Python

        # This is equivalent to Python's `import numpy as np`
        var np = Python.import_module("numpy")
        a = np.array([1, 2, 3])
        ```

        Args:
            module: The Python module name. This module must be visible from the
                list of available Python paths (you might need to add the
                module's path with `add_to_path()`).

        Returns:
            The Python module.
        """
        var cpython = Python().cpython()
        # Throw error if it occurred during initialization
        cpython.check_init_error()
        var module_maybe = cpython.PyImport_ImportModule(module)
        Python.throw_python_exception_if_error_state(cpython)
        return PythonObject(module_maybe)

    @staticmethod
    fn create_module(name: StaticString) raises -> PythonModule:
        """Creates a Python module using the provided name.

        Inspired by https://github.com/pybind/pybind11/blob/a1d00916b26b187e583f3bce39cd59c3b0652c32/include/pybind11/pybind11.h#L1227

        TODO: allow specifying a doc-string to attach to the module upon creation or lazily added?

        Args:
            name: The Python module name.

        Returns:
            The Python module.
        """
        # Initialize the global instance to the Python interpreter
        # in case this is our first time.

        var cpython = Python().cpython()

        # This will throw an error if there are any errors during initialization.
        cpython.check_init_error()

        var module_obj = cpython.PyModule_Create(name)

        # TODO: investigate when `PyModule_Create` can actually produce an error
        # This is cargo copy-pasted from other methods in this file essentially.
        Python.throw_python_exception_if_error_state(cpython)

        return PythonModule(unsafe_unchecked_from=PythonObject(module_obj))

    @staticmethod
    fn add_functions(
        module: PythonModule,
        owned functions: List[PyMethodDef],
    ) raises:
        """Adds functions to a PythonModule object.

        Args:
            module: The PythonModule object.
            functions: List of function data.

        Raises:
            If we fail to add the functions to the module.
        """

        # Write a zeroed entry at the end as a terminator.
        functions.append(PyMethodDef())

        # FIXME(MSTDL-910):
        #   This is an intentional memory leak, because we don't store this
        #   in a global variable (yet).
        var ptr: UnsafePointer[PyMethodDef] = functions.steal_data()

        return Self._unsafe_add_functions(module, ptr)

    @staticmethod
    fn _unsafe_add_functions(
        module: PythonModule,
        functions: UnsafePointer[PyMethodDef],
    ) raises:
        """Adds functions to a PythonModule object.

        Safety:
            The provided `functions` pointer must point to data that lives
            for the duration of the associated Python interpreter session.

        Args:
            module: The PythonModule object.
            functions: A null terminated pointer to function data.

        Raises:
            If we fail to add the functions to the module.
        """
        var cpython = Python().cpython()

        var result = cpython.PyModule_AddFunctions(
            # Safety: `module` pointer lives long enough because its reference
            #   argument.
            module.unsafe_as_py_object_ptr(),
            functions,
        )

        if result != 0:
            Python.throw_python_exception_if_error_state(cpython)

    @staticmethod
    fn add_object(
        module: PythonModule,
        owned name: String,
        value: PythonObject,
    ) raises:
        """Add a new object to `module` with the given name and value.

        The provided object can be any type of Python object: an instance,
        a type object, a function, etc.

        The added value will be inserted into the `__dict__` of the provided
        module.

        Args:
            module: The Python module to modify.
            name: The name of the new object.
            value: The python object value.
        """

        var cpython = Python().cpython()

        var result = cpython.PyModule_AddObjectRef(
            module.unsafe_as_py_object_ptr(),
            name.unsafe_cstr_ptr(),
            value.unsafe_as_py_object_ptr(),
        )

        if result != 0:
            Python.throw_python_exception_if_error_state(cpython)

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    @staticmethod
    fn dict() -> PythonObject:
        """Construct an empty Python dictionary.

        Returns:
            The constructed empty Python dictionary.
        """
        return PythonObject(Dict[PythonObject, PythonObject]())

    @staticmethod
    fn list[*Ts: PythonConvertible](*values: *Ts) -> PythonObject:
        """Construct an Python list of objects.

        Parameters:
            Ts: The list element types.

        Args:
            values: The values to initialize the list with.

        Returns:
            The constructed Python list.
        """
        return PythonObject._list(values)

    @staticmethod
    fn tuple[*Ts: PythonConvertible](*values: *Ts) -> PythonObject:
        """Construct an Python tuple of objects.

        Parameters:
            Ts: The list element types.

        Args:
            values: The values to initialize the tuple with.

        Returns:
            The constructed Python tuple.
        """
        return PythonObject._tuple(values)

    @no_inline
    fn as_string_slice(
        self, str_obj: PythonObject
    ) -> StringSlice[__origin_of(str_obj.py_object.unsized_obj_ptr.origin)]:
        """Return a string representing the given Python object.

        Args:
            str_obj: The Python object.

        Returns:
            Mojo string representing the given Python object.
        """
        var cpython = self.cpython()
        return cpython.PyUnicode_AsUTF8AndSize(str_obj.py_object)

    @staticmethod
    fn throw_python_exception_if_error_state(cpython: CPython) raises:
        """Raise an exception if CPython interpreter is in an error state.

        Args:
            cpython: The cpython instance we wish to error check.
        """
        if cpython.PyErr_Occurred():
            raise Python.unsafe_get_python_exception(cpython)

    @staticmethod
    fn unsafe_get_python_exception(cpython: CPython) -> Error:
        """Get the `Error` object corresponding to the current CPython
        interpreter error state.

        Safety:
            The caller MUST be sure that the CPython interpreter is in an error
            state before calling this function.

        This function will clear the CPython error.

        Args:
            cpython: The cpython instance we wish to error check.

        Returns:
            `Error` object describing the CPython error.
        """
        debug_assert(
            cpython.PyErr_Occurred(),
            "invalid unchecked conversion of Python error to Mojo error",
        )

        var error: Error = String(PythonObject(cpython.PyErr_Fetch()))
        cpython.PyErr_Clear()
        return error

    @staticmethod
    fn is_type(x: PythonObject, y: PythonObject) -> Bool:
        """Test if the `x` object is the `y` object, the same as `x is y` in
        Python.

        Args:
            x: The left-hand-side value in the comparison.
            y: The right-hand-side type value in the comparison.

        Returns:
            True if `x` and `y` are the same object and False otherwise.
        """
        var cpython = Python().cpython()
        return cpython.Py_Is(x.py_object, y.py_object)

    @staticmethod
    fn type(obj: PythonObject) -> PythonObject:
        """Return Type of this PythonObject.

        Args:
            obj: PythonObject we want the type of.

        Returns:
            A PythonObject that holds the type object.
        """
        var cpython = Python().cpython()
        return cpython.PyObject_Type(obj.py_object)

    @staticmethod
    fn none() -> PythonObject:
        """Get a `PythonObject` representing `None`.

        Returns:
            `PythonObject` representing `None`.
        """
        return PythonObject(None)

    # ===-------------------------------------------------------------------===#
    # Checked Conversions
    # ===-------------------------------------------------------------------===#

    @staticmethod
    fn py_long_as_ssize_t(obj: PythonObject) raises -> Py_ssize_t:
        """Get the value of a Python `long` object.

        Args:
            obj: The Python `long` object.

        Raises:
            If `obj` is not a Python `long` object, or if the `long` object
            value overflows `Py_ssize_t`.

        Returns:
            The value of the `long` object as a `Py_ssize_t`.
        """
        var cpython = Python().cpython()

        var long: Py_ssize_t = cpython.PyLong_AsSsize_t(
            obj.unsafe_as_py_object_ptr()
        )

        # Disambiguate if this is an error return setinel, or a legitimate
        # value.
        if long == -1:
            Python.throw_python_exception_if_error_state(cpython)

        return long
