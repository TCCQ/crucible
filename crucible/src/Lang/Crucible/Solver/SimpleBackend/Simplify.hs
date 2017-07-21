{-|
Module      : Lang.Crucible.Solver.SimpleBackend.Simplify
Copyright   : (c) Galois, Inc 2016
License     : BSD3
Maintainer  : Joe Hendrix <jhendrix@galois.com>

This module provides a minimalistic interface for manipulating Boolean formulas
and execution contexts in the symbolic simulator.
-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE ViewPatterns #-}
module Lang.Crucible.Solver.SimpleBackend.Simplify
  ( simplify
  , count_subterms
  ) where

import           Control.Monad.ST
import           Control.Monad.State
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe
import qualified Data.Parameterized.HashTable as PH
import           Data.Parameterized.Nonce
import           Data.Parameterized.TraversableFC
import           Data.Word

import           Lang.Crucible.Solver.Interface
import           Lang.Crucible.Solver.SimpleBuilder

------------------------------------------------------------------------
-- simplify

data NormCache t st
   = NormCache { ncBuilder :: !(SimpleBuilder t st)
               , ncTable :: !(PH.HashTable RealWorld (Elt t) (Elt t))
               }

norm :: NormCache t st -> Elt t tp -> IO (Elt t tp)
norm c e = do
  mr <- stToIO $ PH.lookup (ncTable c) e
  case mr of
    Just r -> return r
    Nothing -> do
      r <- norm' c e
      stToIO $ PH.insert (ncTable c) e r
      return r

bvIteDist :: (BoolElt t -> r -> r -> IO r)
          -> Elt t i
          -> (Elt t i -> IO r)
          -> IO r
bvIteDist muxFn (asApp -> Just (BVIte _ _ c t f)) atomFn = do
  t' <- bvIteDist muxFn t atomFn
  f' <- bvIteDist muxFn f atomFn
  muxFn c t' f'
bvIteDist _ u atomFn = atomFn u

norm' :: forall t st tp . NormCache t st -> Elt t tp -> IO (Elt t tp)
norm' nc (AppElt a0) = do
  let sb = ncBuilder nc
  case appEltApp a0 of
    BVAdd _ x y | (iteSize x >= 1) || (iteSize y >= 1) -> do

      bvIteDist (bvIte sb) x $ \u -> do
      bvIteDist (bvIte sb) y $ \v -> do
      norm nc =<< bvAdd sb u v

    BVNeg _ x | iteSize x > 0 -> do
      bvIteDist (bvIte sb) x $ \u -> do
      norm nc =<< bvNeg sb u
    BVEq (asApp -> Just (BVIte _ _ x_c x_t x_f)) y -> do
      z_t <- bvEq sb x_t y
      z_f <- bvEq sb x_f y
      norm nc =<< itePred sb x_c z_t z_f
    BVEq x (asApp -> Just (BVIte _ _ y_c y_t y_f)) -> do
      z_t <- bvEq sb x y_t
      z_f <- bvEq sb x y_f
      norm nc =<< itePred sb y_c z_t z_f
    BVSlt (asApp -> Just (BVIte _ _ x_c x_t x_f)) y -> do
      z_t <- bvSlt sb x_t y
      z_f <- bvSlt sb x_f y
      norm nc =<< itePred sb x_c z_t z_f
    BVSlt x (asApp -> Just (BVIte _ _ y_c y_t y_f)) -> do
      z_t <- bvSlt sb x y_t
      z_f <- bvSlt sb x y_f
      norm nc =<< itePred sb y_c z_t z_f
    app -> do
      app' <- traverseApp (norm nc) app
      if app' == app then
        return (AppElt a0)
       else
        norm nc =<< sbMakeElt sb app'
norm' nc (NonceAppElt p0) = do
  let predApp = nonceEltApp p0
  p <- traverseFC (norm nc) predApp
  if p == predApp then
    return $! NonceAppElt p0
   else
    norm nc =<< sbNonceElt (ncBuilder nc) p
norm' _ e = return e

-- | Simplify a Boolean expression by distributing over ite.
simplify :: SimpleBuilder t st -> BoolElt t -> IO (BoolElt t)
simplify sb p = do
  tbl <- stToIO $ PH.new
  let nc = NormCache { ncBuilder = sb
                     , ncTable = tbl
                     }
  norm nc p

------------------------------------------------------------------------
-- count_subterm

type Counter = State (Map Word64 Int)

-- | Record an element occurs, and return condition indicating if it is new.
recordElt :: Nonce t (tp::k) -> Counter Bool
recordElt n = do
  m <- get
  let (mr, m') = Map.insertLookupWithKey (\_ -> (+)) (indexValue n) 1 m
  put $ m'
  return $! isNothing mr

count_subterms' :: Elt t tp -> Counter ()
count_subterms' e0 =
  case e0 of
    SemiRingLiteral{} -> pure ()
    BVElt{}  -> pure ()
    AppElt ae -> do
      is_new <- recordElt (appEltId ae)
      when is_new $ do
        traverseFC_ count_subterms' (appEltApp ae)
    NonceAppElt nae -> do
      is_new <- recordElt (nonceEltId nae)
      when is_new $ do
        traverseFC_ count_subterms' (nonceEltApp nae)
    BoundVarElt v -> do
      void $ recordElt (bvarId v)

-- | Return a map from nonce indices to the number of times an elt with that
-- nonce appears in the subterm.
count_subterms :: Elt t tp -> Map Word64 Int
count_subterms e = execState (count_subterms' e) Map.empty

{-
------------------------------------------------------------------------
-- nnf

-- | Convert formula into negation normal form.
nnf :: SimpleBuilder Elt t BoolType -> IO (Elt T BoolType)
nnf e =
-}
