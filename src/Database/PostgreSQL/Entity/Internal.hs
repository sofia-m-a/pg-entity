{-# LANGUAGE Strict #-}
{-|
  Module      : Database.PostgreSQL.Entity.Internal
  Copyright   : © Clément Delafargue, 2018
                  Théophile Choutri, 2021
  License     : MIT
  Maintainer  : theophile@choutri.eu
  Stability   : stable

  Internal helpers used to implement the high-level API and SQL combinators.

  You can re-use those building blocks freely to create your own wrappers.
-}
module Database.PostgreSQL.Entity.Internal
  ( -- * Helpers
    isNotNull
  , isNull
  , inParens
  , quoteName
  , getTableName
  , prefix
  , expandFields
  , expandQualifiedFields
  , expandQualifiedFields'
  , qualifyFields
  , placeholder
  , generatePlaceholders
  , textToQuery
  , queryToText
  , intercalateVector
  ) where

import Data.String (fromString)
import Data.Text (Text, unpack)
import Data.Text.Encoding (decodeUtf8)
import Data.Vector (Vector)
import qualified Data.Vector as V
import Database.PostgreSQL.Simple.Types (Query (..))

import Data.Foldable (fold)
import Database.PostgreSQL.Entity.Internal.Unsafe (Field (Field))
import Database.PostgreSQL.Entity.Types

-- $setup
-- >>> :set -XQuasiQuotes
-- >>> :set -XOverloadedLists
-- >>> :set -XTypeApplications
-- >>> import Database.PostgreSQL.Entity
-- >>> import Database.PostgreSQL.Entity.Internal.BlogPost
-- >>> import Database.PostgreSQL.Entity.Internal.QQ
-- >>> import Database.PostgreSQL.Entity.Internal.Unsafe

-- | Wrap the given text between parentheses
--
-- __Examples__
--
-- >>> inParens "wrap me!"
-- "(wrap me!)"
--
-- @since 0.0.1.0
inParens :: Text -> Text
inParens t = "(" <> t <> ")"

-- | Wrap the given text between double quotes
--
-- __Examples__
--
-- >>> quoteName "meow."
-- "\"meow.\""
--
-- @since 0.0.1.0
quoteName :: Text -> Text
quoteName n = "\"" <> n <> "\""

-- | Safe getter that quotes a table name
--
-- __Examples__
--
-- >>> getTableName @Author
-- "\"authors\""
-- >>> getTableName @Tags
-- "public.\"tags\""
getTableName :: forall e. Entity e => Text
getTableName = prefix (schema @e) <> quoteName (tableName @e)

prefix :: Maybe Text -> Text
prefix = maybe "" (<> ".")

getFieldName :: Field -> Text
getFieldName = quoteName . fieldName

-- | Produce a comma-separated list of an entity's fields.
--
-- __Examples__
--
-- >>> expandFields @BlogPost
-- "\"blogpost_id\", \"author_id\", \"uuid_list\", \"title\", \"content\", \"created_at\""
--
-- @since 0.0.1.0
expandFields :: forall e. Entity e => Text
expandFields = V.foldl1' (\element acc -> element <> ", " <> acc) (getFieldName <$> fields @e)

-- | Produce a comma-separated list of an entity's fields, qualified with the table name
--
-- __Examples__
--
-- >>> expandQualifiedFields @BlogPost
-- "blogposts.\"blogpost_id\", blogposts.\"author_id\", blogposts.\"uuid_list\", blogposts.\"title\", blogposts.\"content\", blogposts.\"created_at\""
--
-- @since 0.0.1.0
expandQualifiedFields :: forall e. Entity e => Text
expandQualifiedFields = expandQualifiedFields' (fields @e) prefixName
  where
    prefixName = tableName @e

-- | Produce a comma-separated list of an entity's 'fields', qualified with an arbitrary prefix
--
-- __Examples__
--
-- >>> expandQualifiedFields' (fields @BlogPost) "legacy"
-- "legacy.\"blogpost_id\", legacy.\"author_id\", legacy.\"uuid_list\", legacy.\"title\", legacy.\"content\", legacy.\"created_at\""
--
-- @since 0.0.1.0
expandQualifiedFields' :: Vector Field -> Text -> Text
expandQualifiedFields' fs prefixName = V.foldl1' (\element acc -> element <> ", " <> acc) fs'
  where
    fs' = fieldName <$> qualifyFields prefixName fs

-- | Take a prefix and a vector of fields, and qualifies each field with the prefix
--
-- __Examples__
--
-- >>> qualifyFields "legacy" (fields @BlogPost)
-- [Field "legacy.\"blogpost_id\"" Nothing,Field "legacy.\"author_id\"" Nothing,Field "legacy.\"uuid_list\"" (Just "uuid[]"),Field "legacy.\"title\"" Nothing,Field "legacy.\"content\"" Nothing,Field "legacy.\"created_at\"" Nothing]
--
-- @since 0.0.1.0
qualifyFields :: Text -> Vector Field -> Vector Field
qualifyFields p fs = fmap (\(Field f t) -> Field (p <> "." <> quoteName f) t) fs

-- | Produce a placeholder of the form @\"field\" = ?@ with an optional type annotation.
--
-- __Examples__
--
-- >>> placeholder [field| id |]
-- "\"id\" = ?"
--
-- >>> placeholder $ [field| ids :: uuid[] |]
-- "\"ids\" = ?::uuid[]"
--
-- >>> fmap placeholder $ fields @BlogPost
-- ["\"blogpost_id\" = ?","\"author_id\" = ?","\"uuid_list\" = ?::uuid[]","\"title\" = ?","\"content\" = ?","\"created_at\" = ?"]
--
-- @since 0.0.1.0
placeholder :: Field -> Text
placeholder (Field f Nothing)  = quoteName f <> " = ?"
placeholder (Field f (Just t)) = quoteName f <> " = ?::" <> t

-- | Generate an appropriate number of “?” placeholders given a vector of fields.
--
-- Used to generate INSERT queries.
--
-- __Examples__
--
-- >>> generatePlaceholders $ fields @BlogPost
-- "?, ?, ?::uuid[], ?, ?, ?"
--
-- @since 0.0.1.0
generatePlaceholders :: Vector Field -> Text
generatePlaceholders vf = fold $ intercalateVector ", " $ fmap ph vf
  where
    ph (Field _ t) = maybe "?" (\t' -> "?::" <> t') t

-- | Produce an IS NOT NULL statement given a vector of fields
--
-- >>> isNotNull [ [field| possibly_empty |] ]
-- "\"possibly_empty\" IS NOT NULL"
--
-- >>> isNotNull [[field| possibly_empty |], [field| that_one_too |]]
-- "\"possibly_empty\" IS NOT NULL AND \"that_one_too\" IS NOT NULL"
--
-- @since 0.0.1.0
isNotNull :: Vector Field -> Text
isNotNull fs' = fold $ intercalateVector " AND " (fmap process fieldNames)
  where
    fieldNames = fmap fieldName fs'
    process f = quoteName f <> " IS NOT NULL"

-- | Produce an IS NULL statement given a vector of fields
--
-- >>> isNull [ [field| possibly_empty |] ]
-- "\"possibly_empty\" IS NULL"
--
-- >>> isNull [[field| possibly_empty |], [field| that_one_too |]]
-- "\"possibly_empty\" IS NULL AND \"that_one_too\" IS NULL"
--
-- @since 0.0.1.0
isNull :: Vector Field -> Text
isNull fs' = fold $ intercalateVector " AND " (fmap process fieldNames)
  where
    fieldNames = fmap fieldName fs'
    process f = quoteName f <> " IS NULL"

-- | Since the 'Query' type has an 'IsString' instance, the process of converting from 'Text' to 'String' to 'Query' is
-- factored into this function
--
-- ⚠ This may be dangerous and an unregulated usage of this function may expose to you SQL injection attacks
-- @since 0.0.1.0
textToQuery :: Text -> Query
textToQuery = fromString . unpack

-- | For cases where combinator composition is tricky, we can safely get back to a 'Text' string from a 'Query'
--
-- ⚠ This may be dangerous and an unregulated usage of this function may expose to you SQL injection attacks
-- @since 0.0.1.0
queryToText :: Query -> Text
queryToText = decodeUtf8 . fromQuery

-- | The 'intercalateVector' function takes a Text and a Vector Text and concatenates the vector after interspersing
-- the first argument between each element of the list.
--
-- __Examples__
--
-- >>> intercalateVector "~" []
-- []
--
-- >>> intercalateVector "~" ["nyan"]
-- ["nyan"]
--
-- >>> intercalateVector "~" ["nyan", "nyan", "nyan"]
-- ["nyan","~","nyan","~","nyan"]
--
-- @since 0.0.1.0
intercalateVector :: Text -> Vector Text -> Vector Text
intercalateVector sep vt | V.null vt = vt
                         | otherwise = V.cons x (go xs)
  where
    (x,xs) = (V.head vt, V.tail vt)
    go :: Vector Text -> Vector Text
    go ys | V.null ys = ys
          | otherwise = V.cons sep (V.cons (V.head ys) (go (V.tail ys)))
