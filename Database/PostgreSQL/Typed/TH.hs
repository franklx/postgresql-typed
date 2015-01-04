{-# LANGUAGE CPP, PatternGuards, ScopedTypeVariables, FlexibleContexts, TemplateHaskell, DataKinds #-}
-- |
-- Module: Database.PostgreSQL.Typed.TH
-- Copyright: 2015 Dylan Simon
-- 
-- Support functions for compile-time PostgreSQL connection and state management.
-- You can use these to build your own Template Haskell functions using the PostgreSQL connection.

module Database.PostgreSQL.Typed.TH
  ( getTPGDatabase
  , withTPGConnection
  , useTPGDatabase
  , TPGValueInfo(..)
  , tpgDescribe
  , tpgTypeEncoder
  , tpgTypeDecoder
  ) where

import Control.Applicative ((<$>), (<$), (<|>))
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar)
import Control.Exception (onException, finally)
import Control.Monad (liftM2)
import qualified Data.Foldable as Fold
import qualified Data.IntMap.Lazy as IntMap
import Data.List (find)
import Data.Maybe (isJust, fromMaybe)
import qualified Data.Traversable as Tv
import qualified Language.Haskell.TH as TH
import Network (PortID(UnixSocket, PortNumber), PortNumber)
import System.Environment (lookupEnv)
import System.IO.Unsafe (unsafePerformIO)

import Database.PostgreSQL.Typed.Types
import Database.PostgreSQL.Typed.Protocol

-- |A particular PostgreSQL type, identified by full formatted name (from @format_type@ or @\\dT@).
type TPGType = String

-- |Generate a 'PGDatabase' based on the environment variables:
-- @TPG_HOST@ (localhost); @TPG_SOCK@ or @TPG_PORT@ (5432); @TPG_DB@ or user; @TPG_USER@ or @USER@ (postgres); @TPG_PASS@ ()
getTPGDatabase :: IO PGDatabase
getTPGDatabase = do
  user <- fromMaybe "postgres" <$> liftM2 (<|>) (lookupEnv "TPG_USER") (lookupEnv "USER")
  db   <- fromMaybe user <$> lookupEnv "TPG_DB"
  host <- fromMaybe "localhost" <$> lookupEnv "TPG_HOST"
  pnum <- maybe (5432 :: PortNumber) ((fromIntegral :: Int -> PortNumber) . read) <$> lookupEnv "TPG_PORT"
  port <- maybe (PortNumber pnum) UnixSocket <$> lookupEnv "TPG_SOCK"
  pass <- fromMaybe "" <$> lookupEnv "TPG_PASS"
  debug <- isJust <$> lookupEnv "TPG_DEBUG"
  return $ defaultPGDatabase
    { pgDBHost = host
    , pgDBPort = port
    , pgDBName = db
    , pgDBUser = user
    , pgDBPass = pass
    , pgDBDebug = debug
    }

tpgState :: MVar (PGDatabase, Maybe TPGState)
tpgState = unsafePerformIO $
  newMVar (unsafePerformIO getTPGDatabase, Nothing)

data TPGState = TPGState
  { tpgConnection :: PGConnection
  , tpgTypes :: IntMap.IntMap TPGType -- keyed on fromIntegral OID
  }

tpgInit :: PGConnection -> IO TPGState
tpgInit c = do
  (_, tl) <- pgSimpleQuery c "SELECT typ.oid, format_type(CASE WHEN typtype = 'd' THEN typbasetype ELSE typ.oid END, -1) FROM pg_catalog.pg_type typ JOIN pg_catalog.pg_namespace nsp ON typnamespace = nsp.oid WHERE nspname <> 'pg_toast' AND nspname <> 'information_schema' ORDER BY typ.oid"
  return $ TPGState
    { tpgConnection = c
    , tpgTypes = IntMap.fromAscList $ map (\[PGTextValue to, PGTextValue tn] ->
        (fromIntegral (pgDecode (PGTypeProxy :: PGTypeName "oid") to :: OID), pgDecode (PGTypeProxy :: PGTypeName "text") tn)) $ Fold.toList tl
    }

-- |Run an action using the Template Haskell state.
withTPGState :: (TPGState -> IO a) -> IO a
withTPGState f = do
  (db, tpg') <- takeMVar tpgState
  tpg <- maybe (tpgInit =<< pgConnect db) return tpg'
    `onException` putMVar tpgState (db, Nothing) -- might leave connection open
  f tpg `finally` putMVar tpgState (db, Just tpg)

-- |Run an action using the Template Haskell PostgreSQL connection.
withTPGConnection :: (PGConnection -> IO a) -> IO a
withTPGConnection f = withTPGState (f . tpgConnection)

-- |Specify an alternative database to use during compilation.
-- This lets you override the default connection parameters that are based on TPG environment variables.
-- This should be called as a top-level declaration and produces no code.
-- It uses 'pgReconnect' so is safe to call multiple times with the same database.
useTPGDatabase :: PGDatabase -> TH.DecsQ
useTPGDatabase db = TH.runIO $ do
  (db', tpg') <- takeMVar tpgState
  putMVar tpgState . (,) db =<<
    (if db == db'
      then Tv.mapM (\t -> do
        c <- pgReconnect (tpgConnection t) db
        return t{ tpgConnection = c }) tpg'
      else Nothing <$ Fold.mapM_ (pgDisconnect . tpgConnection) tpg')
    `onException` putMVar tpgState (db, Nothing)
  return []

-- |Lookup a type name by OID.
-- Error if not found.
tpgType :: TPGState -> OID -> TPGType
tpgType TPGState{ tpgTypes = types } t =
  IntMap.findWithDefault (error $ "Unknown PostgreSQL type: " ++ show t) (fromIntegral t) types

-- |Lookup a type OID by type name.
-- This is less common and thus less efficient than going the other way.
-- Fail if not found.
getTPGTypeOID :: Monad m => TPGState -> String -> m OID
getTPGTypeOID TPGState{ tpgTypes = types } t =
  maybe (fail $ "Unknown PostgreSQL type: " ++ t ++ "; be sure to use the exact type name from \\dTS") (return . fromIntegral . fst)
    $ find ((==) t . snd) $ IntMap.toList types

-- |Determine if a type supports binary format marshalling.
-- Checks for a 'PGBinaryType' instance.  Should be efficient.
tpgTypeIsBinary :: TPGType -> TH.Q Bool
tpgTypeIsBinary t =
  TH.isInstance ''PGBinaryType [TH.LitT (TH.StrTyLit t)]

data TPGValueInfo = TPGValueInfo
  { tpgValueName :: String
  , tpgValueTypeOID :: !OID
  , tpgValueType :: TPGType
  , tpgValueBinary :: Bool
  , tpgValueNullable :: Bool
  }

-- |A type-aware wrapper to 'pgDescribe'
tpgDescribe :: String -> [String] -> Bool -> TH.Q ([TPGValueInfo], [TPGValueInfo])
tpgDescribe sql types nulls = do
  (pv, rv) <- TH.runIO $ withTPGState $ \tpg -> do
    at <- mapM (getTPGTypeOID tpg) types
    (pt, rt) <- pgDescribe (tpgConnection tpg) sql at nulls
    return
      ( map (\o -> TPGValueInfo
        { tpgValueName = ""
        , tpgValueTypeOID = o
        , tpgValueType = tpgType tpg o
        , tpgValueBinary = False
        , tpgValueNullable = True
        }) pt
      , map (\(c, o, n) -> TPGValueInfo
        { tpgValueName = c
        , tpgValueTypeOID = o
        , tpgValueType = tpgType tpg o
        , tpgValueBinary = False
        , tpgValueNullable = n
        }) rt
      )
#ifdef USE_BINARY
  -- now that we're back in Q (and have given up the TPGState) we go back to fill in binary:
  liftM2 (,) (fillBin pv) (fillBin rv)
  where
  fillBin = mapM (\i -> do
    b <- tpgTypeIsBinary (tpgValueType i)
    return i{ tpgValueBinary = b })
#else
  return (pv, rv)
#endif


typeApply :: TPGType -> TH.Name -> TH.Name -> TH.Name -> TH.Exp
typeApply t f e v =
  TH.VarE f `TH.AppE` TH.VarE e
    `TH.AppE` (TH.ConE 'PGTypeProxy `TH.SigE` (TH.ConT ''PGTypeName `TH.AppT` TH.LitT (TH.StrTyLit t)))
    `TH.AppE` TH.VarE v


-- |TH expression to encode a 'PGParameter' value to a 'Maybe' 'L.ByteString'.
tpgTypeEncoder :: Bool -> TPGValueInfo -> TH.Name -> TH.Name -> TH.Exp
tpgTypeEncoder lit v = typeApply (tpgValueType v) $ if lit
  then 'pgEscapeParameter
  else if tpgValueBinary v then 'pgEncodeBinaryParameter else 'pgEncodeParameter

-- |TH expression to decode a 'Maybe' 'L.ByteString' to a ('Maybe') 'PGColumn' value.
tpgTypeDecoder :: TPGValueInfo -> TH.Name -> TH.Name -> TH.Exp
tpgTypeDecoder v = typeApply (tpgValueType v) $ if tpgValueBinary v
  then if tpgValueNullable v then 'pgDecodeBinaryColumn else 'pgDecodeBinaryColumnNotNull
  else if tpgValueNullable v then 'pgDecodeColumn       else 'pgDecodeColumnNotNull