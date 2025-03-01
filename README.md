## Z-Data

[![Hackage](https://img.shields.io/hackage/v/Z-Data.svg?style=flat)](https://hackage.haskell.org/package/Z-Data)
[![Linux Build Status](https://github.com/ZHaskell/z-data/workflows/ubuntu-ci/badge.svg)](https://github.com/ZHaskell/z-data/actions)
[![macOS Build Status](https://github.com/ZHaskell/z-data/workflows/osx-ci/badge.svg)](https://github.com/ZHaskell/z-data/actions)
[![Windows Build Status](https://github.com/ZHaskell/z-data/workflows/win-ci/badge.svg)](https://github.com/ZHaskell/z-data/actions)
[![ARM Build Status](https://img.shields.io/drone/build/ZHaskell/z-data?label=arm-ci)](https://cloud.drone.io/ZHaskell/z-data)
[![Gitter chat](https://badges.gitter.im/gitterHQ/gitter.svg)](https://gitter.im/Z-Haskell/community)
<a href="https://opencollective.com/zhaskell/donate" target="_blank">
  <img src="https://opencollective.com/zhaskell/donate/button@2x.png?color=blue" width=128 />
</a>

This package is part of [ZHaskell](https://z.haskell.world) project, providing basic data structures and functions:

* Array, vector(array slice), sorting, searching
* Text based UTF-8, basic unicode manipulating, regex
* FFI utilties
* Fast parsing and building monad
* JSON encoding and decoding

## Requirements

* A working haskell compiler system, GHC(>=8.6), cabal-install(>=2.4), here're some options:
    * Mac users can get them via [homebew](//brew.sh/): `brew install ghc cabal-install`.
    * Windows users can get them via [chocolatey](//chocolatey.org): `choco install ghc cabal`.
    * Ubuntu users are recommended to use this [ppa](//launchpad.net/~hvr/+archive/ubuntu/ghc).
* A working C/C++ compiler support C++11, here're some options:
    * Mac users can use the `clang` comes with the [XCode](https://developer.apple.com/xcode/) or [XCode Command Line Tools](https://developer.apple.com/downloads):
        * You can install XCode from app store, or XCode Command Line Tools with `sudo xcode-select --install`.
        * If you came across compiling issues like [this](https://stackoverflow.com/questions/58628377/catalina-c-using-cmath-headers-yield-error-no-member-named-signbit-in-th), consider removing redundant SDKs, e.g. `sudo rm -rf /Library/Developer/CommandLineTools/SDKs`
    * Windows users can use the mingw's one comes with GHC, you can use it by adding `your_path_to_ghc\mingw\bin` to your `PATH`.
    * Ubuntu users can install `gcc/g++` by running `sudo apt install build-essential`.
* Tests need [hspec-discover](https://hackage.haskell.org/package/hspec-discover).

## Example usage

```haskell
> import qualified Z.Data.Vector as V
> import qualified Z.Data.Array as A
>
> -- convert from list
> let v = V.pack [1..10] :: V.PrimVector Int  
> -- vector combinators works on arrays as well
> let a = V.pack [1..10] :: A.Array Int   
> -- slicing vector(slice) is O(1)
> V.take 3 v                              
[1,2,3]
-- slicing array is not O(1)
> V.drop 3 a                              
fromListN 7 [4,5,6,7,8,9,10]
>
> V.intersperse 10 v
[1,10,2,10,3,10,4,10,5,10,6,10,7,10,8,10,9,10,10]
>
> V.mergeSort (V.intersperse 10 v) 
[1,2,3,4,5,6,7,8,9,10,10,10,10,10,10,10,10,10,10]
> -- Generic KMP search on vectors
> V.indices (V.singleton 10) (V.intersperse 10 v) True   
[1,3,5,7,9,11,13,15,17,18]
>
> -- quoter for writing numeric vector literals
> :set -XQuasiQuotes 
> :t [V.vecWord|1,2,3,4,5,4,3,2,1|]                     
[V.vecWord|1,2,3,4,5,4,3,2,1|] :: V.PrimVector Word
>
> import qualified Z.Data.Builder as B
> import qualified Z.Data.Text as T
> :set -XOverloadedStrings 
>
> -- Builders can be used with OverloadedStrings
> B.build $ "builders: " >> B.hex (3 :: Word16) >> B.comma >> B.double 1.2345678
[98,117,105,108,100,101,114,115,58,32,48,48,48,51,44,49,46,50,51,52,53,54,55,56]
> 
> B.buildText $ "builders: " >> B.hex (3 :: Word16) >> B.comma >> B.double 1.2345678
"builders: 0003,1.2345678"
>
> import qualified Z.Data.JSON as JSON
> import GHC.Generics
> 
> JSON.parseValue "[1,2,3,4,5]"
([],Right (Array [Number 1.0,Number 2.0,Number 3.0,Number 4.0,Number 5.0]))
>
> -- JSON module support deriving through Generic
> :set -XDeriveAnyClass -XDeriveGeneric
> data Foo = Foo {foo :: Double} deriving (JSON.JSON, Generic)
> JSON.toValue (Foo 0.01)
Object [("foo",Number 1.0e-2)]
> JSON.encodeText (Foo 0.01)
"{\"foo\":1.0e-2}"
```

## Dev guide

```bash
# get code
git clone --recursive git@github.com:ZHaskell/z-data.git 
cd z-data
# build
cabal build
# test
cabal test --test-show-details=direct
# install 
cabal install
# generate document
cabal haddock
```
