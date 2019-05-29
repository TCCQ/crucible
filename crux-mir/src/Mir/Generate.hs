{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE ImplicitParams #-}
-----------------------------------------------------------------------
-- |
-- Module           : Mir.Generate
-- Description      : Produce MIR AST and translate to Crucible
-- Copyright        : (c) Galois, Inc 2018
-- License          : BSD3
-- Stability        : provisional
--
-- This module sets up the process to compile the rust input file,
-- extract the json representation, and parse as the MIR AST.
-- Also, entry point for translating MIR AST into crucible.
-----------------------------------------------------------------------


module Mir.Generate(generateMIR, translateMIR, translateAll, loadPrims) where

import Data.Foldable(fold)

import Control.Lens hiding((<.>))
import Control.Monad (when)
import Control.Monad.ST

import Control.Monad.IO.Class

import qualified Data.Aeson as J
import qualified Data.ByteString.Lazy as B
import qualified Data.Map as M
import qualified Data.Text as T

import System.FilePath
import qualified System.Process as Proc
import           System.Exit (ExitCode(..))
import           System.Directory (doesFileExist, removeFile, getModificationTime)

import GHC.Stack

import Text.PrettyPrint.ANSI.Leijen (Pretty(..))

import qualified Lang.Crucible.CFG.Core as C
import qualified Lang.Crucible.FunctionHandle as C


import Mir.Mir
import Mir.JSON
import Mir.Intrinsics(MIR)
import Mir.PP()
import Mir.Pass(rewriteCollection)
import Mir.Generator(RustModule(..),CollectionState(..), rmCS, rmCFGs, collection)
import Mir.Trans(transCollection, transStatics)
import qualified Mir.TransCustom as Mir

import Debug.Trace 


-- | Run mir-json on the input, generating lib file on disk
-- NOTE: If the rust file has not been modified since the
-- last .mir file was created, this function does nothing
-- This function uses 'failIO' if any error occurs
generateMIR :: (HasCallStack, ?debug::Int) =>
               FilePath          -- ^ location of input file
            -> String            -- ^ file to processes, without extension
            -> IO Collection
generateMIR dir name  = do
  
  let rustFile = dir </> name <.> "rs"
  let mirFile  = dir </> name <.> "mir"
  
  doesFileExist rustFile >>= \case
    True -> return ()
    False -> fail $ "Cannot read " ++ rustFile 

  rustModTime <- getModificationTime rustFile

  let runMirJSON = do (ec, _, _) <- Proc.readProcessWithExitCode "mir-json"
                                    [rustFile, "--crate-type", "lib"] ""
                      return ec

  ec <- doesFileExist mirFile >>= \case 
    True  -> do mirModTime <- getModificationTime mirFile
                if mirModTime >= rustModTime then
                  return ExitSuccess
                else runMirJSON
    False -> runMirJSON

  case ec of
    ExitFailure cd -> fail $ "Error " ++ show cd ++ " while running mir-json on " ++ dir ++ name
    ExitSuccess    -> return ()

  let rlibFile = ("lib" ++ name) <.> "rlib"
  doesFileExist rlibFile >>= \case
    True  -> removeFile rlibFile
    False -> return ()

  f <- B.readFile (dir </> name <.> "mir")
  let c = (J.eitherDecode f) :: Either String Collection
  case c of
      Left msg -> fail $ "JSON Decoding of MIR failed: " ++ msg
      Right col -> do
        when (?debug > 5) $ do
          traceM "--------------------------------------------------------------"
          traceM $ "Generated module: " ++ name
          traceM $ show (pretty col)
          traceM "--------------------------------------------------------------"  
        return col


-- | Location of the rust file with the standard library
libLoc :: String
libLoc = "mir-lib/src/"

-- | load the rs file containing the standard library
loadPrims :: (?debug::Int) => Bool -> IO Collection
loadPrims useStdLib = do

  -- Same order as in https://github.com/rust-lang/rust/blob/master/src/libcore/prelude/v1.rs  
  let lib = if useStdLib then "lib" else "lib_func_only"
  
  -- Only print debugging info in the standard library at high debugging levels
  col <- let ?debug = ?debug - 3 in
         generateMIR libLoc lib
    
  when (?debug > 6) $ do
    traceM "--------------------------------------------------------------"
    traceM $ "Complete Collection: "
    traceM $ show (pretty col)
    traceM "--------------------------------------------------------------"  

  return col



-- | Translate a MIR collection to Crucible
translateMIR :: (HasCallStack, ?debug::Int, ?assertFalseOnError::Bool) 
   => CollectionState -> Collection -> C.HandleAllocator s -> ST s RustModule
translateMIR lib col halloc =
  let ?customOps = Mir.customOps in
  let col0 = let ?mirLib  = lib^.collection in rewriteCollection col
  in let ?libCS = lib in transCollection col0 halloc

-- | Translate a MIR crate *and* the standard library all at once
translateAll :: (?debug::Int, ?assertFalseOnError::Bool)
             => Bool -> Collection -> IO (RustModule, C.AnyCFG MIR)
translateAll usePrims col = do
  prims <- liftIO $ loadPrims usePrims
  let (a,b) = runST $ C.withHandleAllocator $ \halloc -> do
               pmir     <- translateMIR mempty prims halloc
               mir      <- translateMIR (pmir^.rmCS) col halloc
               init_cfg <- transStatics (mir^.rmCS) halloc
               return $ (pmir <> mir, init_cfg)
  return $ (a,b)

