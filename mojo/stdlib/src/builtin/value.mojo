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
"""Defines core value traits.

These are Mojo built-ins, so you don't need to import them.
"""


trait Movable:
    """The Movable trait denotes a type whose value can be moved.

    Implement the `Movable` trait on `Foo` which requires the `__moveinit__`
    method:

    ```mojo
    struct Foo(Movable):
        fn __init__(out self):
            pass

        fn __moveinit__(out self, owned existing: Self):
            print("moving")
    ```

    You can now use the ^ suffix to move the object instead of copying
    it inside generic functions:

    ```mojo
    fn return_foo[T: Movable](owned foo: T) -> T:
        return foo^

    var foo = Foo()
    var res = return_foo(foo^)
    ```

    ```plaintext
    moving
    ```
    """

    fn __moveinit__(out self, owned existing: Self, /):
        """Create a new instance of the value by moving the value of another.

        Args:
            existing: The value to move.
        """
        ...


trait Copyable:
    """The Copyable trait denotes a type whose value can be copied.

    Example implementing the `Copyable` trait on `Foo` which requires the `__copyinit__`
    method:

    ```mojo
    struct Foo(Copyable):
        var s: String

        @implicit
        fn __init__(out self, s: String):
            self.s = s

        fn __copyinit__(out self, other: Self):
            print("copying value")
            self.s = other.s
    ```

    You can now copy objects inside a generic function:

    ```mojo
    fn copy_return[T: Copyable](foo: T) -> T:
        var copy = foo
        return copy

    var foo = Foo("test")
    var res = copy_return(foo)
    ```

    ```plaintext
    copying value
    ```
    """

    fn __copyinit__(out self, existing: Self, /):
        """Create a new instance of the value by copying an existing one.

        Args:
            existing: The value to copy.
        """
        ...


trait ExplicitlyCopyable:
    """The ExplicitlyCopyable trait denotes a type whose value can be copied
    explicitly.

    Unlike `Copyable`, which denotes types that are _implicitly_ copyable, an
    explicitly copyable type can only be copied when the explicit copy
    initializer is called intentionally by the programmer.

    An explicit copy initializer is just a normal `__init__` method that takes
    a `read-only` argument of `Self`.

    Example implementing the `ExplicitlyCopyable` trait on `Foo` which requires
    the `fn(self) -> Self` method:

    ```mojo
    struct Foo(ExplicitlyCopyable):
        var s: String

        @implicit
        fn __init__(out self, s: String):
            self.s = s

        fn copy(self) -> Self:
            print("explicitly copying value")
            return Foo(self.s)
    ```

    You can now copy objects inside a generic function:

    ```mojo
    fn copy_return[T: ExplicitlyCopyable](foo: T) -> T:
        var copy = foo.copy()
        return copy

    var foo = Foo("test")
    var res = copy_return(foo)
    ```

    ```plaintext
    explicitly copying value
    ```
    """

    fn copy(self) -> Self:
        """Explicitly construct a copy of self.

        Returns:
            A copy of this value.
        """
        ...


trait Defaultable:
    """The `Defaultable` trait describes a type with a default constructor.

    Implementing the `Defaultable` trait requires the type to define
    an `__init__` method with no arguments:

    ```mojo
    struct Foo(Defaultable):
        var s: String

        fn __init__(out self):
            self.s = "default"
    ```

    You can now construct a generic `Defaultable` type:

    ```mojo
    fn default_init[T: Defaultable]() -> T:
        return T()

    var foo = default_init[Foo]()
    print(foo.s)
    ```

    ```plaintext
    default
    ```
    """

    fn __init__(out self):
        """Create a default instance of the value."""
        ...


alias CollectionElement = Copyable & Movable


trait CollectionElementNew(ExplicitlyCopyable, Movable):
    """A temporary explicitly-copyable alternative to `CollectionElement`.

    This trait will eventually replace `CollectionElement`.
    """

    pass


trait WritableCollectionElement(CollectionElement, Writable):
    """The WritableCollectionElement trait denotes a trait composition
    of the `CollectionElement` and `Writable` traits.

    This is useful to have as a named entity since Mojo does not
    currently support anonymous trait compositions to constrain
    on `CollectionElement & Stringable` in the parameter.
    """

    pass


trait ComparableCollectionElement(CollectionElement, Comparable):
    """
    This trait denotes a trait composition of the `CollectionElement` and `Comparable` traits.

    This is useful to have as a named entity since Mojo does not
    currently support anonymous trait compositions to constrain
    on `CollectionElement & Comparable` in the parameter.
    """

    pass


trait RepresentableCollectionElement(CollectionElement, Representable):
    """The RepresentableCollectionElement trait denotes a trait composition
    of the `CollectionElement` and `Representable` traits.

    This is useful to have as a named entity since Mojo does not
    currently support anonymous trait compositions to constrain
    on `CollectionElement & Representable` in the parameter.
    """

    pass


trait BoolableCollectionElement(Boolable, CollectionElement):
    """The BoolableCollectionElement trait denotes a trait composition
    of the `Boolable` and `CollectionElement` traits.

    This is useful to have as a named entity since Mojo does not
    currently support anonymous trait compositions to constrain
    on `Boolable & CollectionElement` in the parameter.
    """

    pass


trait BoolableKeyElement(Boolable, KeyElement):
    """The BoolableKeyElement trait denotes a trait composition
    of the `Boolable` and `KeyElement` traits.

    This is useful to have as a named entity since Mojo does not
    currently support anonymous trait compositions to constrain
    on `Boolable & KeyElement` in the parameter.
    """

    pass


trait EqualityComparableWritableCollectionElement(
    WritableCollectionElement, EqualityComparable
):
    """A trait that combines the CollectionElement, Writable and
    EqualityComparable traits.

    This trait requires types to implement CollectionElement, Writable and
    EqualityComparable interfaces, allowing them to be used in collections,
    compared, and written to output.
    """

    pass


trait WritableCollectionElementNew(CollectionElementNew, Writable):
    """A trait that combines the CollectionElement and Writable traits.

    This trait requires types to implement both CollectionElement and Writable
    interfaces, allowing them to be used in collections and written to output.
    """

    pass


trait EqualityComparableWritableCollectionElementNew(
    WritableCollectionElementNew, EqualityComparable
):
    """A trait that combines the CollectionElement, Writable and
    EqualityComparable traits.

    This trait requires types to implement CollectionElement, Writable and
    EqualityComparable interfaces, allowing them to be used in collections,
    compared, and written to output.
    """

    pass
