{-|
Module      : Z.Data.Text.Base
Description : Unicode text processing
Copyright   : (c) Dong Han, 2017-2018
License     : BSD
Maintainer  : winterland1989@gmail.com
Stability   : experimental
Portability : non-portable

A 'Text' wrap a 'Bytes' which will be interpreted using UTF-8 encoding. User should always use 'validate' to construt a 'Text' (instead of using construtor directly or coercing), otherwise illegal UTF-8 encoded codepoints will cause undefined behaviours.

-}

module Z.Data.Text.Base (
  -- * Text type
    Text(..)
  -- * Building text
  , validate, validateASCII
  , validateMaybe, validateASCIIMaybe
  , index, indexMaybe, charByteIndex, indexR, indexMaybeR, charByteIndexR
  -- * Basic creating
  , empty, singleton, copy
  , replicate , cycleN
  -- * Conversion between list
  , pack, packN, packR, packRN
  , unpack, unpackR
  -- * Conversion between codepoint vector
  , fromVector
  , toVector
  -- * Basic interface
  , null
  , length
  , append
  , map', imap'
  , foldl', ifoldl'
  , foldr', ifoldr'
  , concat, concatR, concatMap
  , shuffle, permutations
    -- ** Special folds
  , count, all, any
    -- ** Text display width
  , displayWidth, displayWidthChar
    -- ** normalization
  , NormalizationResult(..), NormalizeMode(..)
  , isNormalized, isNormalizedTo, normalize, normalizeTo
    -- ** Case conversion
    -- $case
  , envLocale
  , caseFold, caseFoldWith, toLower, toLowerWith, toUpper, toUpperWith, toTitle, toTitleWith
    -- ** Unicode category
  , isCategory, spanCategory
   -- ** Collate
  , collate
  , Collator(..)
  -- * Re-exports
  , module Text.Collate
  -- * Constants
  -- ** Locale
  , Locale
  , pattern LocaleDefault
  , pattern LocaleLithuanian
  , pattern LocaleTurkishAndAzeriLatin
  -- ** Category
  , Category
  , pattern CategoryLetterUppercase
  , pattern CategoryLetterLowercase
  , pattern CategoryLetterTitlecase
  , pattern CategoryLetterOther
  , pattern CategoryLetter
  , pattern CategoryCaseMapped
  , pattern CategoryMarkNonSpacing
  , pattern CategoryMarkSpacing
  , pattern CategoryMarkEnclosing
  , pattern CategoryMark
  , pattern CategoryNumberDecimal
  , pattern CategoryNumberLetter
  , pattern CategoryNumberOther
  , pattern CategoryNumber
  , pattern CategoryPunctuationConnector
  , pattern CategoryPunctuationDash
  , pattern CategoryPunctuationOpen
  , pattern CategoryPunctuationClose
  , pattern CategoryPunctuationInitial
  , pattern CategoryPunctuationFinal
  , pattern CategoryPunctuationOther
  , pattern CategoryPunctuation
  , pattern CategorySymbolMath
  , pattern CategorySymbolCurrency
  , pattern CategorySymbolModifier
  , pattern CategorySymbolOther
  , pattern CategorySymbol
  , pattern CategorySeparatorSpace
  , pattern CategorySeparatorLine
  , pattern CategorySeparatorParagraph
  , pattern CategorySeparator
  , pattern CategoryControl
  , pattern CategoryFormat
  , pattern CategorySurrogate
  , pattern CategoryPrivateUse
  , pattern CategoryUnassigned
  , pattern CategoryCompatibility
  , pattern CategoryIgnoreGraphemeCluster
  , pattern CategoryIscntrl
  , pattern CategoryIsprint
  , pattern CategoryIsspace
  , pattern CategoryIsblank
  , pattern CategoryIsgraph
  , pattern CategoryIspunct
  , pattern CategoryIsalnum
  , pattern CategoryIsalpha
  , pattern CategoryIsupper
  , pattern CategoryIslower
  , pattern CategoryIsdigit
  , pattern CategoryIsxdigit
  -- * Misc
  , TextException(..), errorEmptyText
  , c_utf8_validate_ba
  , c_utf8_validate_addr
  , c_ascii_validate_ba
  , c_ascii_validate_addr
 ) where

import           Control.DeepSeq
import           Control.Exception
import           Control.Monad.ST
import           Control.Monad.Primitive
import           Control.Monad
import           Data.Bits
import           Data.Char                 hiding (toLower, toUpper, toTitle)
import qualified Data.CaseInsensitive      as CI
import           Data.Foldable             (foldlM)
import           Data.Hashable             (Hashable(..))
import qualified Data.List                 as List
import           Data.Primitive.PrimArray  hiding (copyPtrToMutablePrimArray)
import           Data.Typeable
import           Data.Int
import           Data.Word
import           Foreign.C.Types           (CSize(..))
import           GHC.Exts
import           GHC.Stack
import           Z.Data.Array
import           Z.Data.ASCII              (c2w, pattern DOUBLE_QUOTE)
import           Z.Data.Text.UTF8Codec
import           Z.Data.Text.UTF8Rewind
import           Z.Data.Vector.Base        (Bytes, PrimVector(..), c_strlen)
import qualified Z.Data.Vector.Base        as V
import qualified Z.Data.Vector.Search      as V
import           System.Random.Stateful    (StatefulGen)
import           System.IO.Unsafe          (unsafeDupablePerformIO)

import           Prelude                   hiding (concat, concatMap,
                                                elem, notElem, null, length, map,
                                                foldl, foldl1, foldr, foldr1,
                                                maximum, minimum, product, sum,
                                                all, any, replicate, traverse)

import           Test.QuickCheck.Arbitrary (Arbitrary(..), CoArbitrary(..))
import           Text.Read                 (Read(..))
import           Text.Collate              hiding (collate)

-- | 'Text' represented as UTF-8 encoded 'Bytes'
--
newtype Text = Text
    { getUTF8Bytes :: Bytes -- ^ Extract UTF-8 encoded 'Bytes' from 'Text'
    } deriving newtype (Monoid, Semigroup)

instance IsList Text where
    type Item Text = Char
    {-# INLINE fromList #-}
    fromList = pack
    {-# INLINE toList #-}
    toList = unpack
    {-# INLINE fromListN #-}
    fromListN = packN

instance Eq Text where
    Text b1 == Text b2 = b1 == b2
    {-# INLINE (==) #-}

instance Ord Text where
    Text b1 `compare` Text b2 = b1 `compare` b2 -- UTF-8 encoding property
    {-# INLINE compare #-}

-- | The escaping rules is different from 'String' 's 'Show' instance, see "Z.Data.Text.Builder.escapeTextJSON"
instance Show Text where
    show = unpack . escapeTextJSON
        where
            escapeTextJSON (Text (V.PrimVector ba@(PrimArray ba#) s l)) = unsafeDupablePerformIO $ do
                let siz = escape_json_string_length ba# s l
                mba@(MutablePrimArray mba#) <- newPrimArray siz
                if siz == l+2   -- no need to escape
                then do
                    writePrimArray mba 0 DOUBLE_QUOTE
                    copyPrimArray mba 1 ba s l
                    writePrimArray mba (l+1) DOUBLE_QUOTE
                else void $ (escape_json_string ba# s l mba# 0)
                ba' <- unsafeFreezePrimArray mba
                return (Text (V.PrimVector ba' 0 siz))

foreign import ccall unsafe escape_json_string_length
    :: ByteArray# -> Int -> Int -> Int

foreign import ccall unsafe escape_json_string
    :: ByteArray# -> Int -> Int -> MutableByteArray# RealWorld -> Int -> IO Int

-- | Accepted syntax and escaping rules are same with 'String', which is different from 'Show' instance.
instance Read Text where
    readPrec = pack <$> readPrec

instance NFData Text where
    rnf (Text bs) = rnf bs

instance Arbitrary Text where
    arbitrary = pack <$> arbitrary
    shrink a = pack <$> shrink (unpack a)

instance CoArbitrary Text where
    coarbitrary = coarbitrary . unpack

instance Hashable Text where
    {-# INLINE hashWithSalt #-}
    hashWithSalt salt (Text bs) = hashWithSalt salt bs

instance IsString Text where
    {-# INLINE fromString #-}
    fromString = pack

-- | case fold with default locale.
instance CI.FoldCase Text where
    {-# INLINE foldCase #-}
    foldCase = caseFold

-- | /O(n)/ Get the nth codepoint from 'Text', throw 'IndexOutOfTextRange'
-- when out of bound.
index :: HasCallStack => Text -> Int -> Char
{-# INLINE index #-}
index t n = case t `indexMaybe` n of Nothing -> throw (IndexOutOfTextRange n callStack)
                                     Just x  -> x

-- | /O(n)/ Get the nth codepoint from 'Text'.
indexMaybe :: Text -> Int -> Maybe Char
{-# INLINE indexMaybe #-}
indexMaybe (Text (V.PrimVector ba s l)) n
    | n < 0 = Nothing
    | otherwise = go s 0
  where
    !end = s + l
    go !i !j
        | i >= end = Nothing
        | j >= n = let !c = decodeChar_ ba i in Just c
        | otherwise = let l' = decodeCharLen ba i in go (i+l') (j+1)

-- | /O(n)/ Find the nth codepoint's byte index (pointing to the nth char's begining byte).
--
-- The index is only meaningful to the whole byte slice, if there's less than n codepoints,
-- the index will point to next byte after the end.
charByteIndex :: Text -> Int -> Int
{-# INLINE charByteIndex #-}
charByteIndex (Text (V.PrimVector ba s l)) n
    | n < 0 = s
    | otherwise = go s 0
  where
    !end = s + l
    go !i !j
        | i >= end = i
        | j >= n = i
        | otherwise = let l' = decodeCharLen ba i in go (i+l') (j+1)

-- | /O(n)/ Get the nth codepoint from 'Text' counting from the end,
-- throw @IndexOutOfVectorRange n callStack@ when out of bound.
indexR :: HasCallStack => Text -> Int -> Char
{-# INLINE indexR #-}
indexR t n = case t `indexMaybeR` n of Nothing -> throw (V.IndexOutOfVectorRange n callStack)
                                       Just x  -> x

-- | /O(n)/ Get the nth codepoint from 'Text' counting from the end.
indexMaybeR :: Text -> Int -> Maybe Char
{-# INLINE indexMaybeR #-}
indexMaybeR (Text (V.PrimVector ba s l)) n
    | n < 0 = Nothing
    | otherwise = go (s+l-1) 0
  where
    go !i !j
        | i < s = Nothing
        | j >= n = let !c = decodeCharReverse_ ba i in Just c
        | otherwise = let l' = decodeCharLenReverse ba i in go (i-l') (j+1)

-- | /O(n)/ Find the nth codepoint's byte index from the end
-- (pointing to the previous char's ending byte).
--
-- The index is only meaningful to the whole byte slice, if there's less than n codepoints,
-- the index will point to previous byte before the start.
charByteIndexR :: Text -> Int -> Int
{-# INLINE charByteIndexR #-}
charByteIndexR (Text (V.PrimVector ba s l)) n
    | n < 0 = s+l
    | otherwise = go (s+l-1) 0
  where
    go !i !j
        | i < s = i
        | j >= n = i
        | otherwise = let l' = decodeCharLenReverse ba i in go (i-l') (j+1)

--------------------------------------------------------------------------------

-- | /O(n)/ Validate a sequence of bytes is UTF-8 encoded.
--
-- Throw 'InvalidUTF8Exception' in case of invalid codepoint.
--
validate :: HasCallStack => Bytes -> Text
{-# INLINE validate #-}
validate bs@(V.PrimVector (PrimArray ba#) (I# s#) l@(I# l#))
    | l == 0 = Text bs
    | c_utf8_validate_ba ba# s# l# > 0 = Text bs
    | otherwise = throw (InvalidUTF8Exception callStack)

-- | /O(n)/ Validate a sequence of bytes is UTF-8 encoded.
--
-- Return 'Nothing' in case of invalid codepoint.
--
validateMaybe :: Bytes -> Maybe Text
{-# INLINE validateMaybe #-}
validateMaybe bs@(V.PrimVector (PrimArray ba#) (I# s#) l@(I# l#))
    | l == 0 = Just (Text bs)
    | c_utf8_validate_ba ba# s# l# > 0 = Just (Text bs)
    | otherwise = Nothing

-- | /O(n)/ Validate a sequence of bytes is all ascii char byte(<128).
--
-- Throw 'InvalidASCIIException' in case of invalid byte, It's not always faster
-- than 'validate', use it only if you want to validate ASCII char sequences.
--
validateASCII :: HasCallStack => Bytes -> Text
{-# INLINE validateASCII #-}
validateASCII bs@(V.PrimVector (PrimArray ba#) (I# s#) l@(I# l#))
    | l == 0 = Text bs
    | c_ascii_validate_ba ba# s# l# > 0 = Text bs
    | otherwise = throw (InvalidASCIIException callStack)

-- | /O(n)/ Validate a sequence of bytes is all ascii char byte(<128).
--
-- Return 'Nothing' in case of invalid byte.
--
validateASCIIMaybe :: Bytes -> Maybe Text
{-# INLINE validateASCIIMaybe #-}
validateASCIIMaybe bs@(V.PrimVector (PrimArray ba#) (I# s#) l@(I# l#))
    | l == 0 = Just (Text bs)
    | c_ascii_validate_ba ba# s# l# > 0 = Just (Text bs)
    | otherwise = Nothing

foreign import ccall unsafe "utf8_validate"
    c_utf8_validate_ba :: ByteArray# -> Int# -> Int# -> Int
foreign import ccall unsafe "utf8_validate_addr"
    c_utf8_validate_addr :: Addr# -> Int -> IO Int
foreign import ccall unsafe "ascii_validate"
    c_ascii_validate_ba :: ByteArray# -> Int# -> Int# -> Int
foreign import ccall unsafe "ascii_validate_addr"
    c_ascii_validate_addr :: Addr# -> Int -> IO Int

data TextException = InvalidUTF8Exception CallStack
                   | InvalidASCIIException CallStack
                   | IndexOutOfTextRange Int CallStack   -- ^ first payload is invalid char index
                   | EmptyText CallStack
                  deriving (Show, Typeable)
instance Exception TextException

errorEmptyText :: HasCallStack => a
{-# INLINE errorEmptyText #-}
errorEmptyText = throw (EmptyText callStack)

--------------------------------------------------------------------------------

-- | /O(n)/ Convert a string into a text
--
-- Alias for @'packN' 'defaultInitSize'@, will be rewritten to a memcpy if possible.
pack :: String -> Text
pack = packN V.defaultInitSize
{-# INLINE CONLIKE [0] pack #-}
{-# RULES "pack/packASCIIAddr" forall addr . pack (unpackCString# addr) = packASCIIAddr addr #-}
{-# RULES "pack/packUTF8Addr" forall addr . pack (unpackCStringUtf8# addr) = packUTF8Addr addr #-}

packASCIIAddr :: Addr# -> Text
{-# INLINE packASCIIAddr #-}
packASCIIAddr addr0# = go addr0#
  where
    len = fromIntegral . unsafeDupablePerformIO $ c_strlen addr0#
    go addr# = runST $ do
        marr <- newPrimArray len
        copyPtrToMutablePrimArray marr 0 (Ptr addr#) len
        arr <- unsafeFreezePrimArray marr
        return $ Text (PrimVector arr 0 len)

packUTF8Addr :: Addr# -> Text
{-# INLINE packUTF8Addr #-}
packUTF8Addr addr0# = validateAndCopy addr0#
  where
    len = fromIntegral . unsafeDupablePerformIO $ c_strlen addr0#
    valid = unsafeDupablePerformIO $ c_utf8_validate_addr addr0# len
    validateAndCopy addr#
        | valid == 0 = packN len (unpackCStringUtf8# addr#) -- three bytes surrogate -> three bytes replacement
                                                            -- two bytes NUL -> \NUL
                                                            -- the result's length will either smaller or equal
        | otherwise  = runST $ do
            marr <- newPrimArray len
            copyPtrToMutablePrimArray marr 0 (Ptr addr#) len
            arr <- unsafeFreezePrimArray marr
            return $ Text (PrimVector arr 0 len)

-- | /O(n)/ Convert a list into a text with an approximate size(in bytes, not codepoints).
--
-- If the encoded bytes length is larger than the size given, we simply double the buffer size
-- and continue building.
--
-- This function is a /good consumer/ in the sense of build/foldr fusion.
--
packN :: Int -> String -> Text
{-# INLINE packN #-}
packN n0 = \ ws0 ->
    Text (V.create' (max 4 n0) (\ marr -> foldlM go (V.IPair 0 marr) ws0))
  where
    -- It's critical that this function get specialized and unboxed
    -- Keep an eye on its core!
    go :: V.IPair (MutablePrimArray s Word8) -> Char -> ST s (V.IPair (MutablePrimArray s Word8))
    go (V.IPair i marr) !c = do
        siz <- getSizeofMutablePrimArray marr
        if i < siz - 3  -- we need at least 4 bytes for safety
        then do
            i' <- encodeChar marr i c
            return (V.IPair i' marr)
        else do
            let !siz' = siz `shiftL` 1
            !marr' <- resizeMutablePrimArray marr siz'
            i' <- encodeChar marr' i c
            return (V.IPair i' marr')

-- | /O(n)/ Alias for @'packRN' 'defaultInitSize'@.
--
packR :: String -> Text
{-# INLINE packR #-}
packR = packRN V.defaultInitSize

-- | /O(n)/ 'packN' in reverse order.
--
-- This function is a /good consumer/ in the sense of build/foldr fusion.
--
packRN :: Int -> String -> Text
{-# INLINE packRN #-}
packRN n0 = \ ws0 -> runST (do let n = max 4 n0
                               marr <- newArr n
                               (V.IPair i marr') <- foldM go (V.IPair n marr) ws0
                               ba <- unsafeFreezeArr marr'
                               return $! Text (V.fromArr ba i (sizeofArr ba-i))
                           )
  where
    go :: V.IPair (MutablePrimArray s Word8) -> Char -> ST s (V.IPair (MutablePrimArray s Word8))
    go (V.IPair i marr) !c = do
        n <- sizeofMutableArr marr
        let l = encodeCharLength c
        if i >= l
        then do _ <- encodeChar marr (i-l) c
                return (V.IPair (i-l) marr)
        else do let !n' = n `shiftL` 1  -- double the buffer
                !marr' <- newArr n'
                copyMutableArr marr' (n+i) marr i (n-i)
                let i' = n+i-l
                _ <- encodeChar marr' i' c
                return (V.IPair i' marr')

-- | /O(n)/ Convert text to a char list.
--
-- Unpacking is done lazily. i.e. we will retain reference to the array until all element are consumed.
--
-- This function is a /good producer/ in the sense of build/foldr fusion.
unpack :: Text -> String
{-# INLINE [1] unpack #-}
unpack (Text (V.PrimVector ba s l)) = go s
  where
    !end = s + l
    go !idx
        | idx >= end = []
        | otherwise = let (# c, i #) = decodeChar ba idx in c : go (idx + i)

unpackFB :: Text -> (Char -> a -> a) -> a -> a
{-# INLINE [0] unpackFB #-}
unpackFB (Text (V.PrimVector ba s l)) k z = go s
  where
    !end = s + l
    go !idx
        | idx >= end = z
        | otherwise = let (# c, i #) = decodeChar ba idx in c `k` go (idx + i)

{-# RULES
"unpack" [~1] forall t . unpack t = build (\ k z -> unpackFB t k z)
"unpackFB" [1] forall t . unpackFB t (:) [] = unpack t
 #-}

-- | /O(n)/ Convert text to a list in reverse order.
--
-- This function is a /good producer/ in the sense of build/foldr fusion.
unpackR :: Text -> String
{-# INLINE [1] unpackR #-}
unpackR (Text (V.PrimVector ba s l)) = go (s+l-1)
  where
    go !idx
        | idx < s = []
        | otherwise = let (# c, i #) = decodeCharReverse ba idx in c : go (idx - i)

unpackRFB :: Text -> (Char -> a -> a) -> a -> a
{-# INLINE [0] unpackRFB #-}
unpackRFB (Text (V.PrimVector ba s l)) k z = go (s+l-1)
  where
    go !idx
        | idx < s = z
        | otherwise = let (# c, i #) = decodeCharReverse ba idx in c `k` go (idx - i)

{-# RULES
"unpackR" [~1] forall t . unpackR t = build (\ k z -> unpackRFB t k z)
"unpackRFB" [1] forall t . unpackRFB t (:) [] = unpackR t
 #-}

-- | /O(1)/. Single char text.
singleton :: Char -> Text
{-# INLINE singleton #-}
singleton c = Text $ V.createN 4 $ \ marr -> encodeChar marr 0 c

-- | /O(1)/. Empty text.
empty :: Text
{-# NOINLINE empty #-}
empty = Text V.empty

-- | /O(n)/. Copy a text from slice.
copy :: Text -> Text
{-# INLINE copy #-}
copy (Text bs) = Text (V.copy bs)

--------------------------------------------------------------------------------
-- * Basic interface

-- | /O(m+n)/
--
-- There's no need to guard empty vector because we guard them for you, so
-- appending empty text are no-ops.
append :: Text -> Text -> Text
append ta tb = Text ( getUTF8Bytes ta `V.append` getUTF8Bytes tb )
{-# INLINE append #-}

-- | /O(1)/ Test whether a text is empty.
null :: Text -> Bool
{-# INLINE null #-}
null (Text bs) = V.null bs

-- |  /O(n)/ The char length of a text.
length :: Text -> Int
{-# INLINE length #-}
length (Text (V.PrimVector ba s l)) = go s 0
  where
    !end = s + l
    go !i !acc | i >= end = acc
               | otherwise = let j = decodeCharLen ba i in go (i+j) (1+acc)

--------------------------------------------------------------------------------
-- * Transformations
--
-- | /O(n)/ 'map' @f@ @t@ is the 'Text' obtained by applying @f@ to
-- each char of @t@. Performs replacement on invalid scalar values.
map' :: (Char -> Char) -> Text -> Text
{-# INLINE map' #-}
map' f (Text (V.PrimVector arr s l)) | l == 0 = empty
                                     | otherwise = Text (V.create' (l+3) (go s 0))
  where
    end = s + l
    -- the 3 bytes buffer is here for optimizing ascii mapping
    -- we do resize if less than 4 bytes left when building
    -- to save us from pre-checking encoding char length everytime
    go :: Int -> Int -> MutablePrimArray s Word8 -> ST s (V.IPair (MutablePrimArray s Word8))
    go !i !j !marr
        | i >= end = return (V.IPair j marr)
        | otherwise = do
            let (# c, d #) = decodeChar arr i
            j' <- encodeChar marr j (f c)
            let !i' = i + d
            siz <- sizeofMutableArr marr
            if  j' < siz - 3
            then go i' j' marr
            else do
                let !siz' = siz `shiftL` 1
                !marr' <- resizeMutablePrimArray marr siz'
                go i' j' marr'

-- | Strict mapping with index.
imap' :: (Int -> Char -> Char) -> Text -> Text
{-# INLINE imap' #-}
imap' f (Text (V.PrimVector arr s l)) | l == 0 = empty
                                      | otherwise = Text (V.create' (l+3) (go s 0 0))
  where
    end = s + l
    go :: Int -> Int -> Int -> MutablePrimArray s Word8 -> ST s (V.IPair (MutablePrimArray s Word8))
    go !i !j !k !marr
        | i >= end = return (V.IPair j marr)
        | otherwise = do
            let (# c, d #) = decodeChar arr i
            j' <- encodeChar marr j (f k c)
            let !i' = i + d
                !k' = k + 1
            siz <- sizeofMutableArr marr
            if  j' < siz - 3
            then go i' j' k' marr
            else do
                let !siz' = siz `shiftL` 1
                !marr' <- resizeMutablePrimArray marr siz'
                go i' j' k' marr'


-- | Shuffle a text using  <https://en.wikipedia.org/wiki/Fisher%E2%80%93Yates_shuffle Fisher-Yates> algorithm.
shuffle :: (StatefulGen g m, PrimMonad m) => g -> Text -> m Text
{-# INLINE shuffle #-}
shuffle g t = fromVector <$> V.shuffle g (toVector t)

-- | Generate all permutation of a text using <https://en.wikipedia.org/wiki/Heap%27s_algorithm Heap's algorithm>.
permutations :: Text -> [Text]
{-# INLINE permutations #-}
permutations t = fromVector <$> V.permutations (toVector t)

--------------------------------------------------------------------------------
--
-- Strict folds
--

-- | Strict left to right fold.
foldl' :: (b -> Char -> b) -> b -> Text -> b
{-# INLINE foldl' #-}
foldl' f z (Text (V.PrimVector arr s l)) = go z s
  where
    !end = s + l
    -- tail recursive; traverses array left to right
    go !acc !i | i < end  = case decodeChar arr i of
                                (# x, d #) -> go (f acc x) (i + d)
               | otherwise = acc

-- | Strict left to right fold with index.
ifoldl' :: (b -> Int ->  Char -> b) -> b -> Text -> b
{-# INLINE ifoldl' #-}
ifoldl' f z (Text (V.PrimVector arr s l)) = go z s 0
  where
    !end = s + l
    go !acc !i !k | i < end  = case decodeChar arr i of
                                    (# x, d #) -> go (f acc k x) (i + d) (k + 1)
                  | otherwise = acc

-- | Strict right to left fold
foldr' :: (Char -> b -> b) -> b -> Text -> b
{-# INLINE foldr' #-}
foldr' f z (Text (V.PrimVector arr s l)) = go z (s+l-1)
  where
    -- tail recursive; traverses array right to left
    go !acc !i | i >= s    = case decodeCharReverse arr i of
                                (# x, d #) -> go (f x acc) (i - d)
               | otherwise = acc

-- | Strict right to left fold with index
--
-- NOTE: the index is counting from 0, not backwards
ifoldr' :: (Int -> Char -> b -> b) -> b -> Text -> b
{-# INLINE ifoldr' #-}
ifoldr' f z (Text (V.PrimVector arr s l)) = go z (s+l-1) 0
  where
    go !acc !i !k | i >= s    = case decodeCharReverse arr i of
                                    (# x, d #) -> go (f k x acc) (i - d) (k + 1)
                  | otherwise = acc


-- | /O(n)/ Concatenate a list of text.
--
-- Note: 'concat' have to force the entire list to filter out empty text and calculate
-- the length for allocation.
concat :: [Text] -> Text
concat = Text . V.concat . coerce
{-# INLINE concat #-}

-- | /O(n)/ Concatenate a list of text in reverse order, e.g. @concat ["hello, world"] == "worldhello"@
--
-- Note: 'concat' have to force the entire list to filter out empty text and calculate
-- the length for allocation.
concatR :: [Text] -> Text
concatR = Text . V.concatR . coerce
{-# INLINE concatR #-}

-- | Map a function over a text and concatenate the results
concatMap :: (Char -> Text) -> Text -> Text
{-# INLINE concatMap #-}
concatMap f = concat . foldr' ((:) . f) []

-- | /O(n)/ 'count' returns count of an element from a text.
count :: Char -> Text -> Int
{-# INLINE count #-}
count c (Text v)
    | encodeCharLength c == 1 = let w = c2w c in V.count w v
    | otherwise = let (Text pat) = singleton c
                  in List.length $ V.indices pat v False

-- | /O(n)/ Applied to a predicate and a text, 'any' determines
-- if any chars of the text satisfy the predicate.
any :: (Char -> Bool) -> Text -> Bool
{-# INLINE any #-}
any f (Text (V.PrimVector arr s l))
    | l <= 0    = False
    | otherwise = case decodeChar arr s of
                    (# x0, d #) -> go (f x0) (s+d)
  where
    !end = s+l
    go !acc !i | acc       = True
               | i >= end  = acc
               | otherwise = case decodeChar arr i of
                                (# x, d #) -> go (acc || f x) (i+d)

-- | /O(n)/ Applied to a predicate and text, 'all' determines
-- if all chars of the text satisfy the predicate.
all :: (Char -> Bool) -> Text -> Bool
{-# INLINE all #-}
all f (Text (V.PrimVector arr s l))
    | l <= 0    = True
    | otherwise = case decodeChar arr s of
                    (# x0, d #) -> go (f x0) (s+d)
  where
    !end = s+l
    go !acc !i | not acc   = False
               | i >= end  = acc
               | otherwise = case decodeChar arr i of
                                (# x, d #) -> go (acc && f x) (i+d)

--------------------------------------------------------------------------------
--
-- Building text

-- | /O(n)/ 'replicate' char n time.
--
replicate :: Int -> Char -> Text
{-# INLINE replicate #-}
replicate n c | n <= 0 = empty
              | otherwise = Text (V.create siz (go 0))
  where
    !csiz = encodeCharLength c
    !siz = n * csiz
    go :: Int -> MutablePrimArray s Word8 -> ST s ()
    go 0 marr = encodeChar marr 0 c >> go csiz marr
    go i marr | i >= siz = return ()
              | otherwise = do copyChar' csiz marr i marr (i-csiz)
                               go (i+csiz) marr

-- | /O(n*m)/ 'cycleN' a text n times.
cycleN :: Int -> Text -> Text
{-# INLINE cycleN #-}
cycleN 0 _ = empty
cycleN n (Text v) = Text (V.cycleN n v)

--------------------------------------------------------------------------------
-- Convert between codepoint vector and text

-- | /O(n)/ convert from a char vector.
fromVector :: V.PrimVector Char -> Text
{-# INLINE fromVector #-}
fromVector (V.PrimVector arr s l) = Text (V.createN l (go s 0))
  where
    end = s+l
    go :: forall s. Int -> Int -> MutablePrimArray s Word8 -> ST s Int
    go !i !j !marr
        | i >= end = return j
        | otherwise = do
            let c = indexPrimArray arr i
            j' <- encodeChar marr j c
            go (i+1) j' marr

-- | /O(n)/ convert to a char vector.
toVector :: Text -> V.PrimVector Char
{-# INLINE toVector #-}
toVector (Text (V.PrimVector arr s l)) = V.createN (l*4) (go s 0)
  where
    end = s+l
    go :: forall s. Int -> Int -> MutablePrimArray s Char -> ST s Int
    go !i !j !marr
        | i >= end = return j
        | otherwise = do
            let (# c, n #) = decodeChar arr i
            writePrimArray marr j c
            go (i+n) (j+1) marr

-- ----------------------------------------------------------------------------
-- ** Normalization
--
-- $normalization

-- | Check if a string is stable in the NFC (Normalization Form C).
isNormalized :: Text -> NormalizationResult
{-# INLINE isNormalized #-}
isNormalized = isNormalizedTo NFC

{-|
Check if a string is stable in the specified Unicode Normalization
Form.

This function can be used as a preprocessing step, before attempting to
normalize a string. Normalization is a very expensive process, it is often
cheaper to first determine if the string is unstable in the requested
normalization form.

The result of the check will be YES if the string is stable and MAYBE or NO
if it is unstable. If the result is MAYBE, the string does not necessarily
have to be normalized.

For more information, please review <http://www.unicode.org/reports/tr15/ Unicode Standard Annex #15 - Unicode
Normalization Forms>.
-}
isNormalizedTo :: NormalizeMode -> Text -> NormalizationResult
isNormalizedTo nmode (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = NormalizedYes
    | otherwise =
        let nflag = normalizeModeToFlag nmode
        in toNormalizationResult (utf8_isnormalized arr# s# l# nflag)

-- | Normalize a string to NFC (Normalization Form C).
normalize :: Text -> Text
{-# INLINE normalize #-}
normalize = normalizeTo NFC

{-|
Normalize a string to the specified Unicode Normalization Form.

The Unicode standard defines two standards for equivalence between
characters: canonical and compatibility equivalence. Canonically equivalent
characters and sequence represent the same abstract character and must be
rendered with the same appearance and behavior. Compatibility equivalent
characters have a weaker equivalence and may be rendered differently.

Unicode Normalization Forms are formally defined standards that can be used
to test whether any two strings of characters are equivalent to each other.
This equivalence may be canonical or compatibility.

The algorithm puts all combining marks into a specified order and uses the
rules for decomposition and composition to transform the string into one of
four Unicode Normalization Forms. A binary comparison can then be used to
determine equivalence.
-}
normalizeTo :: NormalizeMode -> Text -> Text
normalizeTo nmode (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = empty
    | otherwise = unsafeDupablePerformIO $ do
        let nflag = normalizeModeToFlag nmode
            !l'@(I# l'#) = utf8_normalize_length arr# s# l# nflag
        when (l' < 0) (error "impossible happened!")
        !pa@(MutablePrimArray marr#) <- newArr l'
        utf8_normalize arr# s# l# marr# l'# nflag
        arr' <- unsafeFreezeArr pa
        let !v = V.fromArr arr' 0 l'
        return (Text v)

-- functions below will return error if the source ByteArray# is empty
--
foreign import ccall unsafe utf8_isnormalized ::
    ByteArray# -> Int# -> Int# -> CSize -> Int
foreign import ccall unsafe utf8_normalize ::
    ByteArray# -> Int# -> Int# -> MutableByteArray# RealWorld -> Int# -> CSize -> IO ()
foreign import ccall unsafe utf8_normalize_length ::
    ByteArray# -> Int# -> Int# -> CSize -> Int

-- ----------------------------------------------------------------------------
-- ** Case conversions

-- $case

-- | Remove case distinction from UTF-8 encoded text with default locale.
caseFold :: Text -> Text
caseFold = caseFoldWith LocaleDefault

{-|
Remove case distinction from UTF-8 encoded text.

Case folding is the process of eliminating differences between code points
concerning case mapping. It is most commonly used for comparing strings in a
case-insensitive manner. Conversion is fully compliant with the Unicode 7.0
standard.

Although similar to lowercasing text, there are significant differences.
For one, case folding does _not_ take locale into account when converting.
In some cases, case folding can be up to 20% faster than lowercasing the
same text, but the result cannot be treated as correct lowercased text.

Only two locale-specific exception are made when case folding text.
In Turkish, U+0049 LATIN CAPITAL LETTER I maps to U+0131 LATIN SMALL LETTER
DOTLESS I and U+0130 LATIN CAPITAL LETTER I WITH DOT ABOVE maps to U+0069
LATIN SMALL LETTER I.

Although most code points can be case folded without changing length, there are notable
exceptions. For example, U+0130 (LATIN CAPITAL LETTER I WITH DOT ABOVE) maps
to "U+0069 U+0307" (LATIN SMALL LETTER I and COMBINING DOT ABOVE) when
converted to lowercase.

Only a handful of scripts make a distinction between upper- and lowercase.
In addition to modern scripts, such as Latin, Greek, Armenian and Cyrillic,
a few historic or archaic scripts have case. The vast majority of scripts
do not have case distinctions.
-}

caseFoldWith :: Locale -> Text -> Text
caseFoldWith locale (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = empty
    | otherwise = unsafeDupablePerformIO $ do
        let !l'@(I# l'#) = utf8_casefold_length arr# s# l# locale
        when (l' < 0) (error "impossible happened!")
        !pa@(MutablePrimArray marr#) <- newArr l'
        utf8_casefold arr# s# l# marr# l'# locale
        arr' <- unsafeFreezeArr pa
        let !v = V.fromArr arr' 0 l'
        return (Text v)

-- | Convert UTF-8 encoded text to lowercase with default locale.
toLower :: Text -> Text
toLower = toLowerWith LocaleDefault

{-|
Convert UTF-8 encoded text to lowercase.

This function allows conversion of UTF-8 encoded strings to lowercase
without first changing the encoding to UTF-32. Conversion is fully compliant
with the Unicode 7.0 standard.

Although most code points can be converted to lowercase with changing length,
there are notable exceptions. For example, U+0130 (LATIN CAPITAL LETTER I WITH DOT
ABOVE) maps to "U+0069 U+0307" (LATIN SMALL LETTER I and COMBINING DOT
ABOVE) when converted to lowercase.

Only a handful of scripts make a distinction between upper- and lowercase.
In addition to modern scripts, such as Latin, Greek, Armenian and Cyrillic,
a few historic or archaic scripts have case. The vast majority of scripts do
not have case distinctions.

Case mapping is not reversible. That is, @toUpper(toLower(x)) != toLower(toUpper(x))@.

Certain code points (or combinations of code points) apply rules
based on the locale. For more information about these exceptional
code points, please refer to the Unicode standard:
<ftp://ftp.unicode.org/Public/UNIDATA/SpecialCasing.txt>
-}
toLowerWith :: Locale -> Text -> Text
toLowerWith locale (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = empty
    | otherwise = unsafeDupablePerformIO $ do
        let !l'@(I# l'#) = utf8_tolower_length arr# s# l# locale
        when (l' < 0) (error "impossible happened!")
        !pa@(MutablePrimArray marr#) <- newArr l'
        utf8_tolower arr# s# l# marr# l'# locale
        arr' <- unsafeFreezeArr pa
        let !v = V.fromArr arr' 0 l'
        return (Text v)

-- | Convert UTF-8 encoded text to uppercase with default locale.
toUpper :: Text -> Text
toUpper = toUpperWith LocaleDefault

{-|
Convert UTF-8 encoded text to uppercase.

Conversion is fully compliant with the Unicode 7.0 standard.

Although most code points can be converted without changing length, there are notable
exceptions. For example, U+00DF (LATIN SMALL LETTER SHARP S) maps to
"U+0053 U+0053" (LATIN CAPITAL LETTER S and LATIN CAPITAL LETTER S) when
converted to uppercase.

Only a handful of scripts make a distinction between upper and lowercase.
In addition to modern scripts, such as Latin, Greek, Armenian and Cyrillic,
a few historic or archaic scripts have case. The vast majority of scripts
do not have case distinctions.

Case mapping is not reversible. That is, @toUpper(toLower(x)) != toLower(toUpper(x))@.

Certain code points (or combinations of code points) apply rules
based on the locale. For more information about these exceptional
code points, please refer to the Unicode standard:
<ftp://ftp.unicode.org/Public/UNIDATA/SpecialCasing.txt>
-}
toUpperWith :: Locale -> Text -> Text
toUpperWith locale (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = empty
    | otherwise = unsafeDupablePerformIO $ do
        let !l'@(I# l'#) = utf8_toupper_length arr# s# l# locale
        when (l' < 0) (error "impossible happened!")
        !pa@(MutablePrimArray marr#) <- newArr l'
        utf8_toupper arr# s# l# marr# l'# locale
        arr' <- unsafeFreezeArr pa
        let !v = V.fromArr arr' 0 l'
        return (Text v)

-- | Convert UTF-8 encoded text to titlecase with default locale.
toTitle :: Text -> Text
toTitle = toTitleWith LocaleDefault

{-|
Convert UTF-8 encoded text to titlecase.

This function allows conversion of UTF-8 encoded strings to titlecase.
Conversion is fully compliant with the Unicode 7.0 standard.

Titlecase requires a bit more explanation than uppercase and lowercase,
because it is not a common text transformation. Titlecase uses uppercase
for the first letter of each word and lowercase for the rest. Words are
defined as "collections of code points with general category Lu, Ll, Lt, Lm
or Lo according to the Unicode database".

Effectively, any type of punctuation can break up a word, even if this is
not grammatically valid. This happens because the titlecasing algorithm
does not and cannot take grammar rules into account.

@
Text                                 | Titlecase
-------------------------------------|-------------------------------------
The running man                      | The Running Man
NATO Alliance                        | Nato Alliance
You're amazing at building libraries | You'Re Amazing At Building Libraries
@

Although most code points can be converted to titlecase without changing length,
there are notable exceptions. For example, U+00DF (LATIN SMALL LETTER SHARP S) maps to
"U+0053 U+0073" (LATIN CAPITAL LETTER S and LATIN SMALL LETTER S) when
converted to titlecase.

Certain code points (or combinations of code points) apply rules
based on the locale. For more information about these exceptional
code points, please refer to the Unicode standard:
<ftp://ftp.unicode.org/Public/UNIDATA/SpecialCasing.txt>
-}

toTitleWith :: Locale -> Text -> Text
toTitleWith locale (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = empty
    | otherwise = unsafeDupablePerformIO $ do
        let !l'@(I# l'#) = utf8_totitle_length arr# s# l# locale
        when (l' < 0) (error "impossible happened!")
        !pa@(MutablePrimArray marr#) <- newArr l'
        utf8_totitle arr# s# l# marr# l'# locale
        arr' <- unsafeFreezeArr pa
        let !v = V.fromArr arr' 0 l'
        return (Text v)

-- functions below will return error if the source ByteArray# is empty
foreign import ccall unsafe utf8_casefold ::
    ByteArray# -> Int# -> Int# -> MutableByteArray# RealWorld -> Int# -> Locale -> IO ()
foreign import ccall unsafe utf8_casefold_length ::
    ByteArray# -> Int# -> Int# -> Locale -> Int

foreign import ccall unsafe utf8_tolower ::
    ByteArray# -> Int# -> Int# -> MutableByteArray# RealWorld -> Int# -> Locale -> IO ()
foreign import ccall unsafe utf8_tolower_length ::
    ByteArray# -> Int# -> Int# -> Locale -> Int

foreign import ccall unsafe utf8_toupper ::
    ByteArray# -> Int# -> Int# -> MutableByteArray# RealWorld -> Int# -> Locale -> IO ()
foreign import ccall unsafe utf8_toupper_length ::
    ByteArray# -> Int# -> Int# -> Locale -> Int

foreign import ccall unsafe utf8_totitle ::
    ByteArray# -> Int# -> Int# -> MutableByteArray# RealWorld -> Int# -> Locale -> IO ()
foreign import ccall unsafe utf8_totitle_length ::
    ByteArray# -> Int# -> Int# -> Locale -> Int

{-|
Check if the input string conforms to the category specified by the
flags.

This function can be used to check if the code points in a string are part
of a category. Valid flags are members of the "list of categories".
The category for a code point is defined as part of the entry in UnicodeData.txt,
the data file for the Unicode code point database.

By default, the function will treat grapheme clusters as a single code
point. This means that the following string:

@
Code point | Canonical combining class | General category      | Name
---------- | ------------------------- | --------------------- | ----------------------
U+0045     | 0                         | Lu (Uppercase letter) | LATIN CAPITAL LETTER E
U+0300     | 230                       | Mn (Non-spacing mark) | COMBINING GRAVE ACCENT
@

Will match with 'CategoryLetterUppercase' in its entirety, because
the COMBINING GRAVE ACCENT is treated as part of the grapheme cluster. This
is useful when e.g. creating a text parser, because you do not have to
normalize the text first.

If this is undesired behavior, specify the 'CategoryIgnoreGraphemeCluster' flag.

In order to maintain backwards compatibility with POSIX functions
like `isdigit` and `isspace`, compatibility flags have been provided. Note,
however, that the result is only guaranteed to be correct for code points
in the Basic Latin range, between U+0000 and 0+007F. Combining a
compatibility flag with a regular category flag will result in undefined
behavior.
-}

isCategory :: Category -> Text -> Bool
{-# INLINE isCategory #-}
isCategory c (Text (V.PrimVector (PrimArray arr#) (I# s#) l@(I# l#)))
    | l == 0 = True
    | otherwise = utf8_iscategory arr# s# l# c == l


{-|
Try to match as many code points with the matching category flags as possible
and return the prefix and suffix.
-}
spanCategory :: Category -> Text -> (Text, Text)
{-# INLINE spanCategory #-}
spanCategory c (Text (V.PrimVector arr@(PrimArray arr#) s@(I# s#) l@(I# l#)))
    | l == 0 = (empty, empty)
    | otherwise =
        let i = utf8_iscategory arr# s# l# c
        in (Text (V.PrimVector arr s i), Text (V.PrimVector arr (s+i) (l-i)))

-- functions below will return error if the source ByteArray# is empty
foreign import ccall utf8_iscategory :: ByteArray# -> Int# -> Int# -> Category -> Int

-- | Get the display width of a piece of text.
--
-- You shouldn't pass texts with control characters(<0x20, \\DEL), which are counted with -1 width.
--
-- >>> displayWidth "你好世界！"
-- >>> 10
-- >>> displayWidth "hello world!"
-- >>> 12
--
displayWidth :: Text -> Int
{-# INLINE displayWidth #-}
displayWidth (Text (V.PrimVector ba s l)) = go s 0
  where
    !end = s + l
    go !i !acc
        | i >= end = acc
        | otherwise =
            let (# c, n #) = decodeChar ba i
            in go (i+n) (acc + displayWidthChar c)

-- | Get the display width of a 'Char'.
--
-- You shouldn't pass texts with control characters(<0x20, \\DEL), which are counted with -1 width.
displayWidthChar :: Char -> Int
{-# INLINE displayWidthChar #-}
displayWidthChar c =  mk_wcwidth (fromIntegral (fromEnum c))

foreign import ccall unsafe "hs_wcwidth.c mk_wcwidth" mk_wcwidth :: Int32 -> Int

-- | Compare two 'Text's with <https://www.unicode.org/reports/tr10/ Unicode Collation Algorithm>
collate :: Collator -> Text -> Text -> Ordering
{-# INLINE collate #-}
collate cltr = collateWithUnpacker cltr unpack
