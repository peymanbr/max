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
"""Implements a string optimized for storing small strings.

The main type is `InlineString` which implements small-string optimization to avoid
heap allocations for short strings. For strings shorter than `SMALL_CAP` (24 bytes),
the data is stored inline in the struct's memory layout. For longer strings, it
falls back to heap allocation.

Key Features:
- Small-string optimization avoiding heap allocations for short strings
- Efficient concatenation and mutation operations
- UTF-8 encoding support
- Memory safety through bounds checking

The module also provides `_FixedString`, an internal type used by `InlineString` for
the small string optimization case. `_FixedString` provides a fixed-capacity string
implementation with inline storage.

Example:
```mojo
    from collections.string.inline_string import InlineString

    var s = InlineString("Hello")  # Stored inline, no heap allocation
    s += " World"                  # Still inline
    s += " with a much longer string"  # Now uses heap allocation
```
"""

from collections import InlineArray, Optional
from os import abort
from sys import sizeof

from memory import Span, UnsafePointer, memcpy

from utils import Variant

# ===-----------------------------------------------------------------------===#
# InlineString
# ===-----------------------------------------------------------------------===#


@value
struct InlineString(Sized, Stringable, CollectionElement, CollectionElementNew):
    """A string that performs small-string optimization to avoid heap allocations for short strings.
    """

    alias SMALL_CAP: Int = 24

    """The number of bytes of string data that can be stored inline in this
    string before a heap allocation is required.

    If constructed from a heap allocated String that string will be used as the
    layout of this string, even if the given string would fit within the
    small-string capacity of this type."""

    # Fields
    alias Layout = Variant[String, _FixedString[Self.SMALL_CAP]]

    var _storage: Self.Layout

    # ===------------------------------------------------------------------===#
    # Life cycle methods
    # ===------------------------------------------------------------------===#

    fn __init__(out self):
        """Constructs a new empty string."""
        var fixed = _FixedString[Self.SMALL_CAP]()
        self._storage = Self.Layout(fixed^)

    @implicit
    fn __init__(out self, literal: StringLiteral):
        """Constructs a InlineString value given a string literal.

        Args:
            literal: The input constant string.
        """

        if len(literal) <= Self.SMALL_CAP:
            try:
                var fixed = _FixedString[Self.SMALL_CAP](literal)
                self._storage = Self.Layout(fixed^)
            except e:
                abort(
                    "unreachable: Construction of FixedString of validated"
                    " string failed"
                )
                # TODO(#11245):
                #   When support for "noreturn" functions is added,
                #   this false initialization of this type should be unnecessary.
                self._storage = Self.Layout(String())
        else:
            var heap = String(literal)
            self._storage = Self.Layout(heap^)

    @implicit
    fn __init__(out self, owned heap_string: String):
        """Construct a new small string by taking ownership of an existing
        heap-allocated String.

        Args:
            heap_string: The heap string to take ownership of.
        """
        self._storage = Self.Layout(heap_string^)

    fn copy(self) -> Self:
        """Copy the object.

        Returns:
            A copy of the value.
        """
        return self

    # ===------------------------------------------------------------------=== #
    # Operator dunders
    # ===------------------------------------------------------------------=== #

    fn __iadd__(mut self, str_slice: StringSlice):
        """Appends another string to this string.

        Args:
            str_slice: The string to append.
        """
        var total_len = len(self) + str_slice.byte_length()

        # NOTE: Not guaranteed that we're in the small layout even if our
        #       length is shorter than the small capacity.

        if not self._is_small():
            self._storage[String] += str_slice
        elif total_len < Self.SMALL_CAP:
            try:
                self._storage[_FixedString[Self.SMALL_CAP]] += str_slice
            except e:
                abort(
                    "unreachable: InlineString append to FixedString failed: ",
                    e,
                )
        else:
            # We're currently in the small layout but must change to the
            # big layout.

            # Begin by heap allocating enough space to store the combined
            # string.
            var result = String(capacity=total_len)
            # Copy the bytes from the current small string layout
            result += StringSlice(
                ptr=self._storage[_FixedString[Self.SMALL_CAP]].unsafe_ptr(),
                length=len(self),
            )
            # Copy the bytes from the additional string.
            result += str_slice
            self._storage = Self.Layout(result^)

    fn __add__(self, other: StringSlice) -> Self:
        """Construct a string by appending another string at the end of this string.

        Args:
            other: The string to append.

        Returns:
            A new string containing the concatenation of `self` and `other`.
        """

        var string = self
        string += other
        return string^

    fn __add__(self, other: InlineString) -> Self:
        """Construct a string by appending another string at the end of this string.

        Args:
            other: The string to append.

        Returns:
            A new string containing the concatenation of `self` and `other`.
        """

        var string = self
        string += other.as_string_slice()
        return string

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    fn __len__(self) -> Int:
        """Gets the string length, in bytes.

        Returns:
            The string length, in bytes.
        """
        if self._is_small():
            return len(self._storage[_FixedString[Self.SMALL_CAP]])
        else:
            debug_assert(
                self._storage.isa[String](),
                "expected non-small string variant to be String",
            )
            return len(self._storage[String])

    @no_inline
    fn __str__(self) -> String:
        """Gets this string as a standard `String`.

        Returns:
            The string representation of the type.
        """
        if self._is_small():
            return String(self._storage[_FixedString[Self.SMALL_CAP]])
        else:
            return self._storage[String]

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    fn _is_small(self) -> Bool:
        """Returns True if this string is currently in the small-string
        optimization layout."""
        var res: Bool = self._storage.isa[_FixedString[Self.SMALL_CAP]]()

        return res

    fn unsafe_ptr(self) -> UnsafePointer[UInt8]:
        """Returns a pointer to the bytes of string data.

        Returns:
            The pointer to the underlying memory.
        """

        if self._is_small():
            return self._storage[_FixedString[Self.SMALL_CAP]].unsafe_ptr()
        else:
            return self._storage[String].unsafe_ptr()

    @always_inline
    fn as_string_slice(ref self) -> StringSlice[__origin_of(self)]:
        """Returns a string slice of the data owned by this inline string.

        Returns:
            A string slice pointing to the data owned by this inline string.
        """

        # FIXME(MSTDL-160):
        #   Enforce UTF-8 encoding in _FixedString so this is actually
        #   guaranteed to be valid.
        return StringSlice(unsafe_from_utf8=self.as_bytes())

    @always_inline
    fn as_bytes(ref self) -> Span[Byte, __origin_of(self)]:
        """
        Returns a contiguous slice of the bytes owned by this string.

        This does not include the trailing null terminator.

        Returns:
            A contiguous slice pointing to the bytes owned by this string.
        """

        return Span[Byte, __origin_of(self)](
            ptr=self.unsafe_ptr(), length=len(self)
        )


# ===-----------------------------------------------------------------------===#
# __FixedString
# ===-----------------------------------------------------------------------===#


@value
struct _FixedString[CAP: Int](
    Sized,
    Stringable,
    Writable,
    Writer,
    CollectionElement,
    CollectionElementNew,
):
    """A string with a fixed available capacity.

    The string data is stored inline in this structs memory layout.

    Parameters:
        CAP: The fixed-size count of bytes of string storage capacity available.
    """

    # Fields
    var buffer: InlineArray[UInt8, CAP]
    """The underlying storage for the fixed string."""
    var size: Int
    """The number of elements in the vector."""

    # ===------------------------------------------------------------------===#
    # Life cycle methods
    # ===------------------------------------------------------------------===#

    fn __init__(out self):
        """Constructs a new empty string."""
        self.buffer = InlineArray[UInt8, CAP](uninitialized=True)
        self.size = 0

    fn copy(self) -> Self:
        """Copy the object."""
        return self

    fn __init__(out self, literal: StringLiteral) raises:
        """Constructs a FixedString value given a string literal.

        Args:
            literal: The input constant string.
        """
        if len(literal) > CAP:
            raise Error(
                "String literal (len=",
                len(literal),
                ") is longer than FixedString capacity (",
                CAP,
                ")",
            )

        self.buffer = InlineArray[UInt8, CAP](uninitialized=True)
        self.size = len(literal)

        memcpy(self.buffer.unsafe_ptr(), literal.unsafe_ptr(), len(literal))

    # ===------------------------------------------------------------------=== #
    # Factory methods
    # ===------------------------------------------------------------------=== #

    @staticmethod
    fn write[*Ts: Writable](*args: *Ts) -> Self:
        """
        Construct a string by concatenating a sequence of Writable arguments.

        Args:
            args: A sequence of Writable arguments.

        Parameters:
            Ts: The types of the arguments to format. Each type must be satisfy
              `Writable`.

        Returns:
            A string formed by formatting the argument sequence.
        """

        var output = Self()

        @parameter
        fn write_arg[T: Writable](arg: T):
            arg.write_to(output)

        args.each[write_arg]()

        return output^

    # ===------------------------------------------------------------------=== #
    # Operator dunders
    # ===------------------------------------------------------------------=== #

    @always_inline
    fn __iadd__(mut self, str_slice: StringSlice) raises:
        """Appends another string to this string.

        Args:
            str_slice: The string to append.
        """
        var err = self._iadd_non_raising(str_slice._slice)
        if err:
            raise err.value()

    # ===------------------------------------------------------------------=== #
    # Trait implementations
    # ===------------------------------------------------------------------=== #

    @no_inline
    fn __str__(self) -> String:
        return String(self.as_string_slice())

    fn __len__(self) -> Int:
        return self.size

    fn __eq__(self, other: StringSlice) -> Bool:
        """Returns True if this string content is equal to another string.

        Args:
            other: The string to compare against.

        Returns: A boolean indicating if this string content is the same as
            another string.
        """
        return self.as_string_slice() == other

    # ===------------------------------------------------------------------=== #
    # Methods
    # ===------------------------------------------------------------------=== #

    fn _iadd_non_raising(
        mut self,
        bytes: Span[Byte, _],
    ) -> Optional[Error]:
        var total_len = len(self) + len(bytes)

        # Ensure there is sufficient capacity to append `str_slice`
        if total_len > CAP:
            return Optional(
                Error(
                    "Insufficient capacity to append len=",
                    len(bytes),
                    " string to len=",
                    len(self),
                    " FixedString with capacity=",
                    CAP,
                )
            )

        # Append the bytes from `str_slice` at the end of the current string
        memcpy(
            dest=self.buffer.unsafe_ptr() + len(self),
            src=bytes.unsafe_ptr(),
            count=len(bytes),
        )

        self.size = total_len

        return None

    fn write_to[W: Writer](self, mut writer: W):
        writer.write_bytes(self.as_bytes())

    @always_inline
    fn write_bytes(mut self, bytes: Span[Byte, _]):
        """
        Write a byte span to this String.

        Args:
            bytes: The byte span to write to this String. Must NOT be
              null terminated.
        """
        _ = self._iadd_non_raising(bytes)

    fn write[*Ts: Writable](mut self, *args: *Ts):
        """Write a sequence of Writable arguments to the provided Writer.

        Parameters:
            Ts: Types of the provided argument sequence.

        Args:
            args: Sequence of arguments to write to this Writer.
        """

        @parameter
        fn write_arg[T: Writable](arg: T):
            arg.write_to(self)

        args.each[write_arg]()

    fn unsafe_ptr(self) -> UnsafePointer[UInt8]:
        """Retrieves a pointer to the underlying memory.

        Returns:
            The pointer to the underlying memory.
        """
        return self.buffer.unsafe_ptr()

    @always_inline
    fn as_string_slice(ref self) -> StringSlice[__origin_of(self)]:
        """Returns a string slice of the data owned by this fixed string.

        Returns:
            A string slice pointing to the data owned by this fixed string.
        """

        # FIXME(MSTDL-160):
        #   Enforce UTF-8 encoding in _FixedString so this is actually
        #   guaranteed to be valid.
        return StringSlice(unsafe_from_utf8=self.as_bytes())

    @always_inline
    fn as_bytes(ref self) -> Span[Byte, __origin_of(self)]:
        """
        Returns a contiguous slice of the bytes owned by this string.

        This does not include the trailing null terminator.

        Returns:
            A contiguous slice pointing to the bytes owned by this string.
        """

        return Span[Byte, __origin_of(self)](
            ptr=self.unsafe_ptr(), length=self.size
        )
