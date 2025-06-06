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
"""Implements PythonObject.

You can import these APIs from the `python` package. For example:

```mojo
from python import PythonObject
```
"""

from collections import Dict
from hashlib._hasher import _HashableWithHasher, _Hasher
from sys.ffi import c_ssize_t

# This apparently redundant import is needed so PythonBindingsGen.cpp can find
# the StringLiteral declaration.
from builtin.string_literal import StringLiteral
from memory import UnsafePointer

from ._cpython import CPython, PyObjectPtr, PyMethodDef, PyCFunction
from ._bindings import py_c_function_wrapper
from .python import Python


trait PythonConvertible:
    """A trait that indicates a type can be converted to a PythonObject, and
    that specifies the behavior with a `to_python_object` method."""

    fn to_python_object(self) -> PythonObject:
        """Convert a value to a PythonObject.

        Returns:
            A PythonObject representing the value.
        """
        ...


struct _PyIter(Sized):
    """A Python iterator."""

    # ===-------------------------------------------------------------------===#
    # Fields
    # ===-------------------------------------------------------------------===#

    var iterator: PythonObject
    """The iterator object that stores location."""
    var prepared_next_item: PythonObject
    """The next item to vend or zero if there are no items."""
    var is_done: Bool
    """Stores True if the iterator is pointing to the last item."""

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    fn __copyinit__(out self, existing: Self):
        """Copy another iterator.

        Args:
            existing: Initialized _PyIter instance.
        """
        self.iterator = existing.iterator
        self.prepared_next_item = existing.prepared_next_item
        self.is_done = existing.is_done

    @implicit
    fn __init__(out self, iter: PythonObject):
        """Initialize an iterator.

        Args:
            iter: A Python iterator instance.
        """
        var cpython = Python().cpython()
        self.iterator = iter
        var maybe_next_item = cpython.PyIter_Next(self.iterator.py_object)
        if maybe_next_item.is_null():
            self.is_done = True
            self.prepared_next_item = PythonObject(PyObjectPtr())
        else:
            self.prepared_next_item = PythonObject(maybe_next_item)
            self.is_done = False

    fn __init__(out self):
        """Initialize an empty iterator."""
        self.iterator = PythonObject(PyObjectPtr())
        self.is_done = True
        self.prepared_next_item = PythonObject(PyObjectPtr())

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    fn __next__(mut self: _PyIter) -> PythonObject:
        """Return the next item and update to point to subsequent item.

        Returns:
            The next item in the traversable object that this iterator
            points to.
        """
        if not self.iterator:
            return self.iterator
        var cpython = Python().cpython()
        var current = self.prepared_next_item
        var maybe_next_item = cpython.PyIter_Next(self.iterator.py_object)
        if maybe_next_item.is_null():
            self.is_done = True
        else:
            self.prepared_next_item = PythonObject(maybe_next_item)
        return current

    @always_inline
    fn __has_next__(self) -> Bool:
        return self.__len__() > 0

    fn __len__(self) -> Int:
        """Return zero to halt iteration.

        Returns:
            0 if the traversal is complete and 1 otherwise.
        """
        if self.is_done:
            return 0
        else:
            return 1


alias PythonModule = TypedPythonObject["Module"]
alias PyFunction = fn (PythonObject, TypedPythonObject["Tuple"]) -> PythonObject
alias PyFunctionRaising = fn (
    PythonObject, TypedPythonObject["Tuple"]
) raises -> PythonObject


@register_passable
struct TypedPythonObject[type_hint: StaticString](
    PythonConvertible,
    SizedRaising,
):
    """A wrapper around `PythonObject` that indicates the type of the contained
    object.

    The PythonObject structure is entirely dynamically typed. This type provides
    a weak layer of optional static typing.

    Parameters:
        type_hint: The type name hint indicating the static type of this
            object.
    """

    # ===-------------------------------------------------------------------===#
    # Fields
    # ===-------------------------------------------------------------------===#

    var _obj: PythonObject

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    fn __init__(out self, *, owned unsafe_unchecked_from: PythonObject):
        """Construct a TypedPythonObject without any validation that the given
        object is of the specified hinted type.

        Args:
            unsafe_unchecked_from: The PythonObject to construct from. This
                will not be type checked.
        """
        self._obj = unsafe_unchecked_from^

    fn __init__(out self: PythonModule, name: StaticString) raises:
        """Construct a Python module with the given name.

        Args:
            name: The name of the module.

        Raises:
            If the module creation fails.
        """
        self = Python.create_module(name)

    fn __copyinit__(out self, other: Self):
        """Copy an instance of this type.

        Args:
            other: The value to copy.
        """
        self._obj = other._obj

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    fn __len__(self) raises -> Int:
        """Returns the length of the object.

        Returns:
            The length of the object.
        """
        return len(self._obj)

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    fn to_python_object(self) -> PythonObject:
        """Convert the TypedPythonObject to a PythonObject.

        Returns:
            A PythonObject representing the value.
        """
        return self._obj

    # TODO:
    #   This should have origin, or we should do this with a context
    #   manager, to prevent use after ASAP destruction.
    fn unsafe_as_py_object_ptr(self) -> PyObjectPtr:
        """Get the underlying PyObject pointer.

        Returns:
            The underlying PyObject pointer.

        Safety:
            Use-after-free: The caller must take care that `self` outlives the
            usage of the pointer returned by this function.
        """
        return self._obj.unsafe_as_py_object_ptr()

    # ===-------------------------------------------------------------------===#
    # 'Tuple' Operations
    # ===-------------------------------------------------------------------===#

    fn __getitem__[
        I: Indexer
    ](self: TypedPythonObject["Tuple"], pos: I,) raises -> PythonObject:
        """Get an element from this tuple.

        Args:
            pos: The tuple element position to retrieve.

        Parameters:
            I: A type that can be used as an index.

        Returns:
            The value of the tuple element at the specified position.
        """
        var cpython = Python().cpython()

        var item: PyObjectPtr = cpython.PyTuple_GetItem(
            self.unsafe_as_py_object_ptr(),
            index(pos),
        )

        if item.is_null():
            raise Python.unsafe_get_python_exception(cpython)

        # TODO(MSTDL-911): Avoid unnecessary owned reference counts when
        #   returning read-only PythonObject values.
        return PythonObject.from_borrowed_ptr(item)


@register_passable
struct PythonObject(
    ImplicitlyBoolable,
    ImplicitlyIntable,
    Indexer,
    KeyElement,
    SizedRaising,
    Stringable,
    Writable,
    PythonConvertible,
    _HashableWithHasher,
):
    """A Python object."""

    # ===-------------------------------------------------------------------===#
    # Fields
    # ===-------------------------------------------------------------------===#

    var py_object: PyObjectPtr
    """A pointer to the underlying Python object."""

    # ===-------------------------------------------------------------------===#
    # Life cycle methods
    # ===-------------------------------------------------------------------===#

    fn __init__(out self):
        """Initialize the object with a `None` value."""
        self = Self(None)

    fn copy(self) -> Self:
        """Copy the object.

        Returns:
            A copy of the value.
        """
        return self

    @implicit
    fn __init__(out self, ptr: PyObjectPtr):
        """Initialize this object from an owned reference-counted Python object
        pointer.

        Ownership of the reference will be assumed by `PythonObject`.

        Args:
            ptr: The `PyObjectPtr` to take ownership of.
        """
        self.py_object = ptr

    @staticmethod
    fn from_borrowed_ptr(borrowed_ptr: PyObjectPtr) -> Self:
        """Initialize this object from a read-only reference-counted Python
        object pointer.

        The reference count of the pointee object will be incremented, and
        ownership of the additional reference count will be assumed by the
        initialized `PythonObject`.

        The CPython API documentation indicates the ownership semantics of the
        returned object on any function that returns a `PyObject*` value. The
        two possible annotations are:

        * "Return value: New reference."
        * "Return value: Borrowed reference.

        This function should be used to construct a `PythonObject` from the
        pointer returned by 'Borrowed reference'-type objects.

        Args:
            borrowed_ptr: A read-only reference counted pointer to a Python
                object.

        Returns:
            An owned PythonObject pointer.
        """
        var cpython = Python().cpython()

        # SAFETY:
        #   We were passed a Python 'read-only reference', so for it to be
        #   safe to store this reference, we must increment the reference
        #   count to convert this to a 'strong reference'.
        cpython.Py_IncRef(borrowed_ptr)

        return PythonObject(borrowed_ptr)

    @implicit
    fn __init__(out self, owned typed_obj: TypedPythonObject[_]):
        """Construct a PythonObject from a typed object, dropping the type hint
        information.

        This is a no-op at runtime. The only information that is lost is static
        type information.

        Args:
            typed_obj: The typed python object to unwrap.
        """
        self = typed_obj._obj^

        # Mark destroyed so we can transfer out its field.
        __disable_del typed_obj

    # TODO(MSTDL-715):
    #   This initializer should not be necessary, we should need
    #   only the initilaizer from a `NoneType`.
    @doc_private
    @implicit
    fn __init__(out self, none: NoneType._mlir_type):
        """Initialize a none value object from a `None` literal.

        Args:
            none: None.
        """
        self = Self(none=NoneType())

    @implicit
    fn __init__(out self, none: NoneType):
        """Initialize a none value object from a `None` literal.

        Args:
            none: None.
        """
        cpython = Python().cpython()
        self.py_object = cpython.Py_None()
        cpython.Py_IncRef(self.py_object)

    @implicit
    fn __init__(out self, value: Bool):
        """Initialize the object from a bool.

        Args:
            value: The boolean value.
        """
        cpython = Python().cpython()
        self.py_object = cpython.PyBool_FromLong(Int(value))

    @implicit
    fn __init__(out self, integer: Int):
        """Initialize the object with an integer value.

        Args:
            integer: The integer value.
        """
        cpython = Python().cpython()
        self.py_object = cpython.PyLong_FromSsize_t(integer)

    @implicit
    fn __init__[dtype: DType](out self, value: SIMD[dtype, 1]):
        """Initialize the object with a generic scalar value. If the scalar
        value type is bool, it is converted to a boolean. Otherwise, it is
        converted to the appropriate integer or floating point type.

        Parameters:
            dtype: The scalar value type.

        Args:
            value: The scalar value.
        """
        var cpython = Python().cpython()

        @parameter
        if dtype is DType.bool:
            self.py_object = cpython.PyBool_FromLong(Int(value))
        elif dtype.is_unsigned():
            var uint_val = value.cast[DType.index]().value
            self.py_object = cpython.PyLong_FromSize_t(uint_val)
        elif dtype.is_integral():
            var int_val = value.cast[DType.index]().value
            self.py_object = cpython.PyLong_FromSsize_t(int_val)
        else:
            var fp_val = value.cast[DType.float64]()
            self.py_object = cpython.PyFloat_FromDouble(fp_val)

    @implicit
    fn __init__(out self, value: StringLiteral):
        """Initialize the object from a string literal.

        Args:
            value: The string value.
        """
        self = PythonObject(value.as_string_slice())

    @implicit
    fn __init__(out self, value: String):
        """Initialize the object from a string.

        Args:
            value: The string value.
        """
        self = PythonObject(value.as_string_slice())

    @implicit
    fn __init__(out self, string: StringSlice):
        """Initialize the object from a string.

        Args:
            string: The string value.
        """
        cpython = Python().cpython()
        self.py_object = cpython.PyUnicode_DecodeUTF8(string)

    @always_inline
    @staticmethod
    fn list[T: PythonConvertible & CollectionElement](values: Span[T]) -> Self:
        """Initialize the object from a list of values.

        Parameters:
            T: The span element type.

        Args:
            values: The values to initialize the list with.

        Returns:
            A PythonObject representing the list.
        """
        var cpython = Python().cpython()
        var py_object = cpython.PyList_New(len(values))

        for i in range(len(values)):
            var obj = values[i].to_python_object()
            cpython.Py_IncRef(obj.py_object)
            _ = cpython.PyList_SetItem(py_object, i, obj.py_object)
        return py_object

    @always_inline
    @staticmethod
    fn list[*Ts: PythonConvertible](*values: *Ts) -> Self:
        """Initialize the object from a list of values.

        Parameters:
            Ts: The list element types.

        Args:
            values: The values to initialize the list with.

        Returns:
            A PythonObject representing the list.
        """
        return Self._list(values)

    @staticmethod
    fn _list[
        *Ts: PythonConvertible
    ](values: VariadicPack[_, _, PythonConvertible, *Ts]) -> Self:
        """Initialize the object from a list literal.

        Parameters:
            Ts: The list element types.

        Args:
            values: The values to initialize the list with.

        Returns:
            A PythonObject representing the list.
        """
        var cpython = Python().cpython()
        var py_object = cpython.PyList_New(len(values))

        @parameter
        for i in range(len(VariadicList(Ts))):
            var obj = values[i].to_python_object()
            cpython.Py_IncRef(obj.py_object)
            _ = cpython.PyList_SetItem(py_object, i, obj.py_object)
        return py_object

    @always_inline
    @staticmethod
    fn tuple[*Ts: PythonConvertible](*values: *Ts) -> Self:
        """Initialize the object from a tuple literal.

        Parameters:
            Ts: The tuple element types.

        Args:
            values: The values to initialize the tuple with.

        Returns:
            A PythonObject representing the tuple.
        """
        return Self._tuple(values)

    @staticmethod
    fn _tuple[
        *Ts: PythonConvertible
    ](values: VariadicPack[_, _, PythonConvertible, *Ts]) -> Self:
        """Initialize the object from a tuple literal.

        Parameters:
            Ts: The tuple element types.

        Args:
            values: The values to initialize the tuple with.

        Returns:
            A PythonObject representing the tuple.
        """
        var cpython = Python().cpython()
        var py_object = cpython.PyTuple_New(len(values))

        @parameter
        for i in range(len(VariadicList(Ts))):
            var obj = values[i].to_python_object()
            cpython.Py_IncRef(obj.py_object)
            _ = cpython.PyTuple_SetItem(py_object, i, obj.py_object)
        return py_object

    @implicit
    fn __init__(out self, slice: Slice):
        """Initialize the object from a Mojo Slice.

        Args:
            slice: The dictionary value.
        """
        self.py_object = _slice_to_py_object_ptr(slice)

    @implicit
    fn __init__(out self, value: Dict[Self, Self]):
        """Initialize the object from a dictionary of PythonObjects.

        Args:
            value: The dictionary value.
        """
        var cpython = Python().cpython()
        self.py_object = cpython.PyDict_New()
        for entry in value.items():
            _ = cpython.PyDict_SetItem(
                self.py_object, entry[].key.py_object, entry[].value.py_object
            )

    fn __copyinit__(out self, existing: Self):
        """Copy the object.

        This increments the underlying refcount of the existing object.

        Args:
            existing: The value to copy.
        """
        self.py_object = existing.py_object
        var cpython = Python().cpython()
        cpython.Py_IncRef(self.py_object)

    fn __del__(owned self):
        """Destroy the object.

        This decrements the underlying refcount of the pointed-to object.
        """
        var cpython = Python().cpython()
        # Acquire GIL such that __del__ can be called safely for cases where the
        # PyObject is handled in non-python contexts.
        var state = cpython.PyGILState_Ensure()
        if not self.py_object.is_null():
            cpython.Py_DecRef(self.py_object)
        self.py_object = PyObjectPtr()
        cpython.PyGILState_Release(state)

    # ===-------------------------------------------------------------------===#
    # Operator dunders
    # ===-------------------------------------------------------------------===#

    fn __iter__(self) raises -> _PyIter:
        """Iterate over the object.

        Returns:
            An iterator object.

        Raises:
            If the object is not iterable.
        """
        var cpython = Python().cpython()
        var iter = cpython.PyObject_GetIter(self.py_object)
        Python.throw_python_exception_if_error_state(cpython)
        return _PyIter(PythonObject(iter))

    fn __getattr__(self, owned name: String) raises -> PythonObject:
        """Return the value of the object attribute with the given name.

        Args:
            name: The name of the object attribute to return.

        Returns:
            The value of the object attribute with the given name.
        """
        var cpython = Python().cpython()
        var result = cpython.PyObject_GetAttrString(self.py_object, name^)
        Python.throw_python_exception_if_error_state(cpython)
        if result.is_null():
            raise Error("Attribute is not found.")
        return PythonObject(result)

    fn __setattr__(self, owned name: String, new_value: PythonObject) raises:
        """Set the given value for the object attribute with the given name.

        Args:
            name: The name of the object attribute to set.
            new_value: The new value to be set for that attribute.
        """
        return self._setattr(name^, new_value.py_object)

    fn _setattr(self, owned name: String, new_value: PyObjectPtr) raises:
        var cpython = Python().cpython()
        var result = cpython.PyObject_SetAttrString(
            self.py_object, name^, new_value
        )
        Python.throw_python_exception_if_error_state(cpython)
        if result < 0:
            raise Error("Attribute is not found or could not be set.")

    fn __bool__(self) -> Bool:
        """Evaluate the boolean value of the object.

        Returns:
            Whether the object evaluates as true.
        """
        var cpython = Python().cpython()
        return cpython.PyObject_IsTrue(self.py_object) == 1

    @always_inline
    fn __as_bool__(self) -> Bool:
        """Evaluate the boolean value of the object.

        Returns:
            Whether the object evaluates as true.
        """
        return self.__bool__()

    fn __is__(self, other: PythonObject) -> Bool:
        """Test if the PythonObject is the `other` PythonObject, the same as `x is y` in
        Python.

        Args:
            other: The right-hand-side value in the comparison.

        Returns:
            True if they are the same object and False otherwise.
        """
        var cpython = Python().cpython()
        return cpython.Py_Is(self.py_object, other.py_object)

    fn __isnot__(self, other: PythonObject) -> Bool:
        """Test if the PythonObject is not the `other` PythonObject, the same as `x is not y` in
        Python.

        Args:
            other: The right-hand-side value in the comparison.

        Returns:
            True if they are not the same object and False otherwise.
        """
        return not (self is other)

    fn __getitem__(self, *args: PythonObject) raises -> PythonObject:
        """Return the value for the given key or keys.

        Args:
            args: The key or keys to access on this object.

        Returns:
            The value corresponding to the given key for this object.
        """
        var cpython = Python().cpython()
        var size = len(args)
        var key_obj: PyObjectPtr
        if size == 1:
            key_obj = args[0].py_object
        else:
            key_obj = cpython.PyTuple_New(size)
            for i in range(size):
                var arg_value = args[i].py_object
                cpython.Py_IncRef(arg_value)
                var result = cpython.PyTuple_SetItem(key_obj, i, arg_value)
                if result != 0:
                    raise Error("internal error: PyTuple_SetItem failed")

        cpython.Py_IncRef(key_obj)
        var result = cpython.PyObject_GetItem(self.py_object, key_obj)
        cpython.Py_DecRef(key_obj)
        Python.throw_python_exception_if_error_state(cpython)
        return PythonObject(result)

    fn __getitem__(self, *args: Slice) raises -> PythonObject:
        """Return the sliced value for the given Slice or Slices.

        Args:
            args: The Slice or Slices to apply to this object.

        Returns:
            The sliced value corresponding to the given Slice(s) for this object.
        """
        var cpython = Python().cpython()
        var size = len(args)
        var key_obj: PyObjectPtr

        if size == 1:
            key_obj = _slice_to_py_object_ptr(args[0])
        else:
            key_obj = cpython.PyTuple_New(size)
            for i in range(size):
                var slice_obj = _slice_to_py_object_ptr(args[i])
                var result = cpython.PyTuple_SetItem(key_obj, i, slice_obj)
                if result != 0:
                    raise Error("internal error: PyTuple_SetItem failed")

        cpython.Py_IncRef(key_obj)
        var result = cpython.PyObject_GetItem(self.py_object, key_obj)
        cpython.Py_DecRef(key_obj)
        Python.throw_python_exception_if_error_state(cpython)
        return PythonObject(result)

    fn __setitem__(mut self, *args: PythonObject, value: PythonObject) raises:
        """Set the value with the given key or keys.

        Args:
            args: The key or keys to set on this object.
            value: The value to set.
        """
        var cpython = Python().cpython()
        var size = len(args)
        var key_obj: PyObjectPtr

        if size == 1:
            key_obj = args[0].py_object
        else:
            key_obj = cpython.PyTuple_New(size)
            for i in range(size):
                var arg_value = args[i].py_object
                cpython.Py_IncRef(arg_value)
                var result = cpython.PyTuple_SetItem(key_obj, i, arg_value)
                if result != 0:
                    raise Error("internal error: PyTuple_SetItem failed")

        cpython.Py_IncRef(key_obj)
        cpython.Py_IncRef(value.py_object)
        var result = cpython.PyObject_SetItem(
            self.py_object, key_obj, value.py_object
        )
        if result != 0:
            Python.throw_python_exception_if_error_state(cpython)
        cpython.Py_DecRef(key_obj)
        cpython.Py_DecRef(value.py_object)

    fn _call_zero_arg_method(
        self, owned method_name: String
    ) raises -> PythonObject:
        var cpython = Python().cpython()
        var tuple_obj = cpython.PyTuple_New(0)
        var callable_obj = cpython.PyObject_GetAttrString(
            self.py_object, method_name^
        )
        if callable_obj.is_null():
            raise Error("internal error: PyObject_GetAttrString failed")
        var result = cpython.PyObject_CallObject(callable_obj, tuple_obj)
        cpython.Py_DecRef(tuple_obj)
        cpython.Py_DecRef(callable_obj)
        return PythonObject(result)

    fn _call_single_arg_method(
        self, owned method_name: String, rhs: PythonObject
    ) raises -> PythonObject:
        var cpython = Python().cpython()
        var tuple_obj = cpython.PyTuple_New(1)
        var result = cpython.PyTuple_SetItem(tuple_obj, 0, rhs.py_object)
        if result != 0:
            raise Error("internal error: PyTuple_SetItem failed")
        cpython.Py_IncRef(rhs.py_object)
        var callable_obj = cpython.PyObject_GetAttrString(
            self.py_object, method_name^
        )
        if callable_obj.is_null():
            raise Error("internal error: PyObject_GetAttrString failed")
        var result_obj = cpython.PyObject_CallObject(callable_obj, tuple_obj)
        cpython.Py_DecRef(tuple_obj)
        cpython.Py_DecRef(callable_obj)
        return PythonObject(result_obj)

    fn _call_single_arg_inplace_method(
        mut self, owned method_name: String, rhs: PythonObject
    ) raises:
        var cpython = Python().cpython()
        var tuple_obj = cpython.PyTuple_New(1)
        var result = cpython.PyTuple_SetItem(tuple_obj, 0, rhs.py_object)
        if result != 0:
            raise Error("internal error: PyTuple_SetItem failed")

        cpython.Py_IncRef(rhs.py_object)
        var callable_obj = cpython.PyObject_GetAttrString(
            self.py_object, method_name^
        )
        if callable_obj.is_null():
            raise Error("internal error: PyObject_GetAttrString failed")

        # Destroy previously stored pyobject
        if not self.py_object.is_null():
            cpython.Py_DecRef(self.py_object)

        self.py_object = cpython.PyObject_CallObject(callable_obj, tuple_obj)
        cpython.Py_DecRef(tuple_obj)
        cpython.Py_DecRef(callable_obj)

    fn __mul__(self, rhs: PythonObject) raises -> PythonObject:
        """Multiplication.

        Calls the underlying object's `__mul__` method.

        Args:
            rhs: Right hand value.

        Returns:
            The product.
        """
        return self._call_single_arg_method("__mul__", rhs)

    fn __rmul__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse multiplication.

        Calls the underlying object's `__rmul__` method.

        Args:
            lhs: The left-hand-side value that is multiplied by this object.

        Returns:
            The product of the multiplication.
        """
        return self._call_single_arg_method("__rmul__", lhs)

    fn __imul__(mut self, rhs: PythonObject) raises:
        """In-place multiplication.

        Calls the underlying object's `__imul__` method.

        Args:
            rhs: The right-hand-side value by which this object is multiplied.
        """
        return self._call_single_arg_inplace_method("__mul__", rhs)

    fn __add__(self, rhs: PythonObject) raises -> PythonObject:
        """Addition and concatenation.

        Calls the underlying object's `__add__` method.

        Args:
            rhs: Right hand value.

        Returns:
            The sum or concatenated values.
        """
        return self._call_single_arg_method("__add__", rhs)

    fn __radd__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse addition and concatenation.

        Calls the underlying object's `__radd__` method.

        Args:
            lhs: The left-hand-side value to which this object is added or
                 concatenated.

        Returns:
            The sum.
        """
        return self._call_single_arg_method("__radd__", lhs)

    fn __iadd__(mut self, rhs: PythonObject) raises:
        """Immediate addition and concatenation.

        Args:
            rhs: The right-hand-side value that is added to this object.
        """
        return self._call_single_arg_inplace_method("__add__", rhs)

    fn __sub__(self, rhs: PythonObject) raises -> PythonObject:
        """Subtraction.

        Calls the underlying object's `__sub__` method.

        Args:
            rhs: Right hand value.

        Returns:
            The difference.
        """
        return self._call_single_arg_method("__sub__", rhs)

    fn __rsub__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse subtraction.

        Calls the underlying object's `__rsub__` method.

        Args:
            lhs: The left-hand-side value from which this object is subtracted.

        Returns:
            The result of subtracting this from the given value.
        """
        return self._call_single_arg_method("__rsub__", lhs)

    fn __isub__(mut self, rhs: PythonObject) raises:
        """Immediate subtraction.

        Args:
            rhs: The right-hand-side value that is subtracted from this object.
        """
        return self._call_single_arg_inplace_method("__sub__", rhs)

    fn __floordiv__(self, rhs: PythonObject) raises -> PythonObject:
        """Return the division of self and rhs rounded down to the nearest
        integer.

        Calls the underlying object's `__floordiv__` method.

        Args:
            rhs: The right-hand-side value by which this object is divided.

        Returns:
            The result of dividing this by the right-hand-side value, modulo any
            remainder.
        """
        return self._call_single_arg_method("__floordiv__", rhs)

    fn __rfloordiv__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse floor division.

        Calls the underlying object's `__rfloordiv__` method.

        Args:
            lhs: The left-hand-side value that is divided by this object.

        Returns:
            The result of dividing the given value by this, modulo any
            remainder.
        """
        return self._call_single_arg_method("__rfloordiv__", lhs)

    fn __ifloordiv__(mut self, rhs: PythonObject) raises:
        """Immediate floor division.

        Args:
            rhs: The value by which this object is divided.
        """
        return self._call_single_arg_inplace_method("__floordiv__", rhs)

    fn __truediv__(self, rhs: PythonObject) raises -> PythonObject:
        """Division.

        Calls the underlying object's `__truediv__` method.

        Args:
            rhs: The right-hand-side value by which this object is divided.

        Returns:
            The result of dividing the right-hand-side value by this.
        """
        return self._call_single_arg_method("__truediv__", rhs)

    fn __rtruediv__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse division.

        Calls the underlying object's `__rtruediv__` method.

        Args:
            lhs: The left-hand-side value that is divided by this object.

        Returns:
            The result of dividing the given value by this.
        """
        return self._call_single_arg_method("__rtruediv__", lhs)

    fn __itruediv__(mut self, rhs: PythonObject) raises:
        """Immediate division.

        Args:
            rhs: The value by which this object is divided.
        """
        return self._call_single_arg_inplace_method("__truediv__", rhs)

    fn __mod__(self, rhs: PythonObject) raises -> PythonObject:
        """Return the remainder of self divided by rhs.

        Calls the underlying object's `__mod__` method.

        Args:
            rhs: The value to divide on.

        Returns:
            The remainder of dividing self by rhs.
        """
        return self._call_single_arg_method("__mod__", rhs)

    fn __rmod__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse modulo.

        Calls the underlying object's `__rmod__` method.

        Args:
            lhs: The left-hand-side value that is divided by this object.

        Returns:
            The remainder from dividing the given value by this.
        """
        return self._call_single_arg_method("__rmod__", lhs)

    fn __imod__(mut self, rhs: PythonObject) raises:
        """Immediate modulo.

        Args:
            rhs: The right-hand-side value that is used to divide this object.
        """
        return self._call_single_arg_inplace_method("__mod__", rhs)

    fn __xor__(self, rhs: PythonObject) raises -> PythonObject:
        """Exclusive OR.

        Args:
            rhs: The right-hand-side value with which this object is exclusive
                 OR'ed.

        Returns:
            The exclusive OR result of this and the given value.
        """
        return self._call_single_arg_method("__xor__", rhs)

    fn __rxor__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse exclusive OR.

        Args:
            lhs: The left-hand-side value that is exclusive OR'ed with this
                 object.

        Returns:
            The exclusive OR result of the given value and this.
        """
        return self._call_single_arg_method("__rxor__", lhs)

    fn __ixor__(mut self, rhs: PythonObject) raises:
        """Immediate exclusive OR.

        Args:
            rhs: The right-hand-side value with which this object is
                 exclusive OR'ed.
        """
        return self._call_single_arg_inplace_method("__xor__", rhs)

    fn __or__(self, rhs: PythonObject) raises -> PythonObject:
        """Bitwise OR.

        Args:
            rhs: The right-hand-side value with which this object is bitwise
                 OR'ed.

        Returns:
            The bitwise OR result of this and the given value.
        """
        return self._call_single_arg_method("__or__", rhs)

    fn __ror__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse bitwise OR.

        Args:
            lhs: The left-hand-side value that is bitwise OR'ed with this
                 object.

        Returns:
            The bitwise OR result of the given value and this.
        """
        return self._call_single_arg_method("__ror__", lhs)

    fn __ior__(mut self, rhs: PythonObject) raises:
        """Immediate bitwise OR.

        Args:
            rhs: The right-hand-side value with which this object is bitwise
                 OR'ed.
        """
        return self._call_single_arg_inplace_method("__or__", rhs)

    fn __and__(self, rhs: PythonObject) raises -> PythonObject:
        """Bitwise AND.

        Args:
            rhs: The right-hand-side value with which this object is bitwise
                 AND'ed.

        Returns:
            The bitwise AND result of this and the given value.
        """
        return self._call_single_arg_method("__and__", rhs)

    fn __rand__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse bitwise and.

        Args:
            lhs: The left-hand-side value that is bitwise AND'ed with this
                 object.

        Returns:
            The bitwise AND result of the given value and this.
        """
        return self._call_single_arg_method("__rand__", lhs)

    fn __iand__(mut self, rhs: PythonObject) raises:
        """Immediate bitwise AND.

        Args:
            rhs: The right-hand-side value with which this object is bitwise
                 AND'ed.
        """
        return self._call_single_arg_inplace_method("__and__", rhs)

    fn __rshift__(self, rhs: PythonObject) raises -> PythonObject:
        """Bitwise right shift.

        Args:
            rhs: The right-hand-side value by which this object is bitwise
                 shifted to the right.

        Returns:
            This value, shifted right by the given value.
        """
        return self._call_single_arg_method("__rshift__", rhs)

    fn __rrshift__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse bitwise right shift.

        Args:
            lhs: The left-hand-side value that is bitwise shifted to the right
                 by this object.

        Returns:
            The given value, shifted right by this.
        """
        return self._call_single_arg_method("__rrshift__", lhs)

    fn __irshift__(mut self, rhs: PythonObject) raises:
        """Immediate bitwise right shift.

        Args:
            rhs: The right-hand-side value by which this object is bitwise
                 shifted to the right.
        """
        return self._call_single_arg_inplace_method("__rshift__", rhs)

    fn __lshift__(self, rhs: PythonObject) raises -> PythonObject:
        """Bitwise left shift.

        Args:
            rhs: The right-hand-side value by which this object is bitwise
                 shifted to the left.

        Returns:
            This value, shifted left by the given value.
        """
        return self._call_single_arg_method("__lshift__", rhs)

    fn __rlshift__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse bitwise left shift.

        Args:
            lhs: The left-hand-side value that is bitwise shifted to the left
                 by this object.

        Returns:
            The given value, shifted left by this.
        """
        return self._call_single_arg_method("__rlshift__", lhs)

    fn __ilshift__(mut self, rhs: PythonObject) raises:
        """Immediate bitwise left shift.

        Args:
            rhs: The right-hand-side value by which this object is bitwise
                 shifted to the left.
        """
        return self._call_single_arg_inplace_method("__lshift__", rhs)

    fn __pow__(self, exp: PythonObject) raises -> PythonObject:
        """Raises this object to the power of the given value.

        Args:
            exp: The exponent.

        Returns:
            The result of raising this by the given exponent.
        """
        return self._call_single_arg_method("__pow__", exp)

    fn __rpow__(self, lhs: PythonObject) raises -> PythonObject:
        """Reverse power of.

        Args:
            lhs: The number that is raised to the power of this object.

        Returns:
            The result of raising the given value by this exponent.
        """
        return self._call_single_arg_method("__rpow__", lhs)

    fn __ipow__(mut self, rhs: PythonObject) raises:
        """Immediate power of.

        Args:
            rhs: The exponent.
        """
        return self._call_single_arg_inplace_method("__pow__", rhs)

    fn __lt__(self, rhs: PythonObject) raises -> PythonObject:
        """Less than comparator. This lexicographically compares strings and
        lists.

        Args:
            rhs: Right hand value.

        Returns:
            True if the object is less than the right hard argument.
        """
        return self._call_single_arg_method("__lt__", rhs)

    fn __le__(self, rhs: PythonObject) raises -> PythonObject:
        """Less than or equal to comparator. This lexicographically compares
        strings and lists.

        Args:
            rhs: Right hand value.

        Returns:
            True if the object is less than or equal to the right hard argument.
        """
        return self._call_single_arg_method("__le__", rhs)

    fn __gt__(self, rhs: PythonObject) raises -> PythonObject:
        """Greater than comparator. This lexicographically compares the elements
        of strings and lists.

        Args:
            rhs: Right hand value.

        Returns:
            True if the left hand value is greater.
        """
        return self._call_single_arg_method("__gt__", rhs)

    fn __ge__(self, rhs: PythonObject) raises -> PythonObject:
        """Greater than or equal to comparator. This lexicographically compares
        the elements of strings and lists.

        Args:
            rhs: Right hand value.

        Returns:
            True if the left hand value is greater than or equal to the right
            hand value.
        """
        return self._call_single_arg_method("__ge__", rhs)

    fn __eq__(self, rhs: PythonObject) -> Bool:
        """Equality comparator. This compares the elements of strings and lists.

        Args:
            rhs: Right hand value.

        Returns:
            True if the objects are equal.
        """
        # TODO: make this function raise when we can raise parametrically.
        try:
            return self._call_single_arg_method("__eq__", rhs).__bool__()
        except e:
            debug_assert(False, "object doesn't implement __eq__")
            return False

    fn __ne__(self, rhs: PythonObject) -> Bool:
        """Inequality comparator. This compares the elements of strings and
        lists.

        Args:
            rhs: Right hand value.

        Returns:
            True if the objects are not equal.
        """
        # TODO: make this function raise when we can raise parametrically.
        try:
            return self._call_single_arg_method("__ne__", rhs).__bool__()
        except e:
            debug_assert(False, "object doesn't implement __eq__")
            return False

    fn __pos__(self) raises -> PythonObject:
        """Positive.

        Calls the underlying object's `__pos__` method.

        Returns:
            The result of prefixing this object with a `+` operator. For most
            numerical objects, this does nothing.
        """
        return self._call_zero_arg_method("__pos__")

    fn __neg__(self) raises -> PythonObject:
        """Negative.

        Calls the underlying object's `__neg__` method.

        Returns:
            The result of prefixing this object with a `-` operator. For most
            numerical objects, this returns the negative.
        """
        return self._call_zero_arg_method("__neg__")

    fn __invert__(self) raises -> PythonObject:
        """Inversion.

        Calls the underlying object's `__invert__` method.

        Returns:
            The logical inverse of this object: a bitwise representation where
            all bits are flipped, from zero to one, and from one to zero.
        """
        return self._call_zero_arg_method("__invert__")

    fn __contains__(self, rhs: PythonObject) raises -> Bool:
        """Contains dunder.

        Calls the underlying object's `__contains__` method.

        Args:
            rhs: Right hand value.

        Returns:
            True if rhs is in self.
        """
        # TODO: replace/optimize with c-python function.
        # TODO: implement __getitem__ step for cpython membership test operator.
        var cpython = Python().cpython()
        if cpython.PyObject_HasAttrString(self.py_object, "__contains__"):
            return self._call_single_arg_method("__contains__", rhs).__bool__()
        for v in self:
            if v == rhs:
                return True
        return False

    # see https://github.com/python/cpython/blob/main/Objects/call.c
    # for decrement rules
    fn __call__(
        self, *args: PythonObject, **kwargs: PythonObject
    ) raises -> PythonObject:
        """Call the underlying object as if it were a function.

        Args:
            args: Positional arguments to the function.
            kwargs: Keyword arguments to the function.

        Raises:
            If the function cannot be called for any reason.

        Returns:
            The return value from the called object.
        """
        var cpython = Python().cpython()

        var num_pos_args = len(args)
        var tuple_obj = cpython.PyTuple_New(num_pos_args)
        for i in range(num_pos_args):
            var arg_value = args[i].py_object
            cpython.Py_IncRef(arg_value)
            var result = cpython.PyTuple_SetItem(tuple_obj, i, arg_value)
            if result != 0:
                raise Error("internal error: PyTuple_SetItem failed")

        var dict_obj = cpython.PyDict_New()
        for entry in kwargs.items():
            var key = cpython.PyUnicode_DecodeUTF8(
                entry[].key.as_string_slice()
            )
            var result = cpython.PyDict_SetItem(
                dict_obj, key, entry[].value.py_object
            )
            if result != 0:
                raise Error("internal error: PyDict_SetItem failed")

        var callable_obj = self.py_object
        cpython.Py_IncRef(callable_obj)
        var result = cpython.PyObject_Call(callable_obj, tuple_obj, dict_obj)
        cpython.Py_DecRef(callable_obj)
        cpython.Py_DecRef(tuple_obj)
        cpython.Py_DecRef(dict_obj)
        Python.throw_python_exception_if_error_state(cpython)
        # Python always returns non null on success.
        # A void function returns the singleton None.
        # If the result is null, something went awry;
        # an exception should have been thrown above.
        if result.is_null():
            raise Error(
                "Call returned null value, indicating failure. Void functions"
                " return NoneType."
            )
        return PythonObject(result)

    # ===-------------------------------------------------------------------===#
    # Trait implementations
    # ===-------------------------------------------------------------------===#

    fn __len__(self) raises -> Int:
        """Returns the length of the object.

        Returns:
            The length of the object.
        """
        var cpython = Python().cpython()
        var result = cpython.PyObject_Length(self.py_object)
        if result == -1:
            # TODO: Improve error message so we say
            # "object of type 'int' has no len()" function to match Python
            raise Error("object has no len()")
        return result

    fn __hash__(self) -> UInt:
        """Returns the length of the object.

        Returns:
            The length of the object.
        """
        var cpython = Python().cpython()
        var result = cpython.PyObject_Length(self.py_object)
        # TODO: make this function raise when we can raise parametrically.
        debug_assert(result != -1, "object is not hashable")
        return result

    fn __hash__[H: _Hasher](self, mut hasher: H):
        """Updates hasher with this python object hash value.

        Parameters:
            H: The hasher type.

        Args:
            hasher: The hasher instance.
        """
        var cpython = Python().cpython()
        var result = cpython.PyObject_Hash(self.py_object)
        # TODO: make this function raise when we can raise parametrically.
        debug_assert(result != -1, "object is not hashable")
        hasher.update(result)

    fn __index__(self) -> __mlir_type.index:
        """Returns an index representation of the object.

        Returns:
            An index value that represents this object.
        """
        return self.__int__().value

    fn __int__(self) -> Int:
        """Returns an integral representation of the object.

        Returns:
            An integral value that represents this object.
        """
        cpython = Python().cpython()
        var py_long = cpython.PyNumber_Long(self.py_object)
        return cpython.PyLong_AsSsize_t(py_long)

    fn __as_int__(self) -> Int:
        """Implicitly convert to an Int.

        Returns:
            An integral value that represents this object.
        """
        return self.__int__()

    fn __float__(self) -> Float64:
        """Returns a float representation of the object.

        Returns:
            A floating point value that represents this object.
        """
        cpython = Python().cpython()
        return cpython.PyFloat_AsDouble(self.py_object)

    @deprecated("Use `Float64(obj)` instead.")
    fn to_float64(self) -> Float64:
        """Returns a float representation of the object.

        Returns:
            A floating point value that represents this object.
        """
        return self.__float__()

    fn __str__(self) -> String:
        """Returns a string representation of the object.

        Calls the underlying object's `__str__` method.

        Returns:
            A string that represents this object.
        """
        var cpython = Python().cpython()
        var python_str: PythonObject = cpython.PyObject_Str(self.py_object)
        # copy the string
        var mojo_str = String(
            cpython.PyUnicode_AsUTF8AndSize(python_str.py_object)
        )
        # keep python object alive so the copy can occur
        _ = python_str
        return mojo_str

    fn write_to[W: Writer](self, mut writer: W):
        """
        Formats this Python object to the provided Writer.

        Parameters:
            W: A type conforming to the Writable trait.

        Args:
            writer: The object to write to.
        """

        # TODO: Avoid this intermediate String allocation, if possible.
        writer.write(String(self))

    # ===-------------------------------------------------------------------===#
    # Methods
    # ===-------------------------------------------------------------------===#

    fn to_python_object(self) -> PythonObject:
        """Convert this value to a PythonObject.

        Returns:
            A PythonObject representing the value.
        """
        return self

    fn unsafe_as_py_object_ptr(self) -> PyObjectPtr:
        """Get the underlying PyObject pointer.

        Returns:
            The underlying PyObject pointer.

        Safety:
            Use-after-free: The caller must take care that `self` outlives the
            usage of the pointer returned by this function.
        """
        return self.py_object

    fn steal_data(owned self) -> PyObjectPtr:
        """Take ownership of the underlying pointer from the Python object.

        Returns:
            The underlying data.
        """
        var ptr = self.py_object
        self.py_object = PyObjectPtr()

        return ptr

    fn unsafe_get_as_pointer[
        dtype: DType
    ](self) -> UnsafePointer[Scalar[dtype]]:
        """Convert a Python-owned and managed pointer into a Mojo pointer.

        Warning: converting from an integer to a pointer is unsafe! The
        compiler assumes the resulting pointer DOES NOT alias any Mojo-derived
        pointer. This is OK because the pointer originates from Python.

        Parameters:
            dtype: The desired DType of the pointer.

        Returns:
            An `UnsafePointer` for the underlying Python data.
        """
        var tmp = Int(self)
        var result = UnsafePointer(to=tmp).bitcast[
            UnsafePointer[Scalar[dtype]]
        ]()[]
        _ = tmp
        return result

    fn _get_ptr_as_int(self) -> Int:
        return self.py_object._get_ptr_as_int()

    fn _get_type_name(self) -> String:
        var cpython = Python().cpython()

        var actual_type = cpython.Py_TYPE(self.unsafe_as_py_object_ptr())
        var actual_type_name = PythonObject(cpython.PyType_GetName(actual_type))

        return String(actual_type_name)


# ===-----------------------------------------------------------------------===#
# Helper functions
# ===-----------------------------------------------------------------------===#


fn _slice_to_py_object_ptr(slice: Slice) -> PyObjectPtr:
    """Convert Mojo Slice to Python slice parameters.

    Deliberately avoids using `span.indices()` here and instead passes
    the Slice parameters directly to Python. Python's C implementation
    already handles such conditions, allowing Python to apply its own slice
    handling and error handling.


    Args:
        slice: A Mojo slice object to be converted.

    Returns:
        PyObjectPtr: The pointer to the Python slice.

    """
    var cpython = Python().cpython()
    var py_start = cpython.Py_None()
    var py_stop = cpython.Py_None()
    var py_step = cpython.Py_None()

    if slice.start:
        py_start = cpython.PyLong_FromSsize_t(c_ssize_t(slice.start.value()))
    if slice.end:
        py_stop = cpython.PyLong_FromSsize_t(c_ssize_t(slice.end.value()))
    if slice.step:
        py_step = cpython.PyLong_FromSsize_t(c_ssize_t(slice.step.value()))

    var py_slice = cpython.PySlice_New(py_start, py_stop, py_step)

    if py_start != cpython.Py_None():
        cpython.Py_DecRef(py_start)
    if py_stop != cpython.Py_None():
        cpython.Py_DecRef(py_stop)
    cpython.Py_DecRef(py_step)

    return py_slice
