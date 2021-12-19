{-|
  Module      : Database.PostgreSQL.Entity.DBT
  Copyright   : © Clément Delafargue, 2018
                  Théophile Choutri, 2021
  License     : MIT
  Maintainer  : theophile@choutri.eu
  Stability   : stable

  The 'Database.PostgreSQL.Transact.DBT' plumbing module to handle database queries and pools
-}
module Database.PostgreSQL.Entity.DBT
  ( mkPool
  , withPool
  , withPool'
  , execute
  , query
  , query_
  , queryOne
  , queryOne_
  , QueryNature(..)
  ) where

import Colourista.IO (cyanMessage, redMessage, yellowMessage)
import Control.Monad.IO.Class
import Control.Monad.Trans.Control (MonadBaseControl)
import Data.Int
import Data.Maybe (listToMaybe)
import Data.Pool (Pool, createPool, withResource)
import Data.Text.Encoding (decodeUtf8)
import Data.Time (NominalDiffTime)
import Data.Vector (Vector)
import qualified Data.Vector as V

import Control.Monad.Catch (Exception, MonadCatch, try)
import Database.PostgreSQL.Simple as PG (ConnectInfo, Connection, FromRow, Query, ToRow, close, connect)
import qualified Database.PostgreSQL.Transact as PGT

-- | Create a Pool Connection with the appropriate parameters
--
-- @since 0.0.1.0
mkPool :: ConnectInfo     -- Database access information
       -> Int             -- Number of sub-pools
       -> NominalDiffTime -- Allowed timeout
       -> Int             -- Number of connections
       -> IO (Pool Connection)
mkPool connectInfo subPools timeout connections =
  createPool (connect connectInfo) close subPools timeout connections

-- | Run a DBT action with no explicit error handling.
--
-- This functions is suited for using 'MonadError' error handling.
--
-- === __Example__
--
-- > let e1 = E 1 True True
-- > result <- runExceptT @EntityError $ do
-- >   withPool pool $ insertEntity e1
-- >   withPool pool $ markForProcessing 1
-- > case result of
-- >   Left err -> print err
-- >   Right _  -> putStrLn "Everything went well"
--
-- See the code in the @example/@ directory on GitHub
--
-- @since 0.0.1.0
withPool :: (MonadBaseControl IO m)
         => Pool Connection -> PGT.DBT m a -> m a
withPool pool action = withResource pool $ PGT.runDBTSerializable action

-- | Run a DBT action while handling errors as Exceptions.
--
-- This function wraps the DBT actions in a 'try', so that exceptions
-- raised will be converted to the Left branch of the Either.
--
-- @since 0.0.1.0
withPool' :: forall errorType result m
          . (Exception errorType, MonadCatch m, MonadBaseControl IO m)
         => Pool Connection
         -> PGT.DBT m result
         -> m (Either errorType result)
withPool' pool action = try $ withPool pool action

-- | Query wrapper that returns a 'Vector' of results
--
-- @since 0.0.1.0
query :: (ToRow params, FromRow result, MonadIO m)
          => QueryNature -> Query -> params -> PGT.DBT m (Vector result)
query queryNature q params = do
  logQueryFormat queryNature q params
  V.fromList <$> PGT.query q params

-- | Query wrapper that returns a 'Vector' of results and does not take an argument
--
-- @since 0.0.1.0
query_ :: (FromRow result, MonadIO m)
       => QueryNature -> Query -> PGT.DBT m (Vector result)
query_ queryNature q = do
  logQueryFormat queryNature q ()
  V.fromList <$> PGT.query_ q

-- | Query wrapper that returns one result.
--
-- @since 0.0.1.0
queryOne :: (ToRow params, FromRow result, MonadIO m)
         => QueryNature -> Query -> params -> PGT.DBT m (Maybe result)
queryOne queryNature q params = do
  logQueryFormat queryNature q params
  listToMaybe <$> PGT.query q params

--
-- | Query wrapper that returns one result and does not take an argument
--
-- @since 0.0.2.0
queryOne_ :: (FromRow result, MonadIO m)
         => QueryNature -> Query -> PGT.DBT m (Maybe result)
queryOne_ queryNature q = do
  logQueryFormat queryNature q ()
  listToMaybe <$> PGT.query_ q

-- | Query wrapper for SQL statements which do not return.
--
-- @since 0.0.1.0
execute :: (ToRow params, MonadIO m)
        => QueryNature -> Query -> params -> PGT.DBT m Int64
execute queryNature q params = do
  logQueryFormat queryNature q params
  PGT.execute q params

logQueryFormat :: (ToRow params, MonadIO m) => QueryNature -> Query -> params -> PGT.DBT m ()
logQueryFormat queryNature q params = do
  msg <- PGT.formatQuery q params
  case queryNature of
    Select -> liftIO $ cyanMessage   $ "[SELECT] " <> decodeUtf8 msg
    Update -> liftIO $ yellowMessage $ "[UPDATE] " <> decodeUtf8 msg
    Insert -> liftIO $ yellowMessage $ "[INSERT] " <> decodeUtf8 msg
    Delete -> liftIO $ redMessage    $ "[DELETE] " <> decodeUtf8 msg

-- | This sum type is given to the 'query', 'queryOne' and 'execute' functions to help
-- with logging.
--
-- @since 0.0.1.0
data QueryNature = Select | Insert | Update | Delete deriving (Eq, Show)
