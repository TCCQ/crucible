{-# LANGUAGE DataKinds #-}
{-# LANGUAGE EmptyCase #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE ImplicitParams #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE PatternGuards #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeInType #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE UndecidableInstances #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE PartialTypeSignatures #-}

-- Turn off some warnings during active development
{-# OPTIONS_GHC -Wincomplete-patterns -Wall
                -fno-warn-unused-imports
                -fno-warn-name-shadowing
                -fno-warn-unused-matches
                -fno-warn-unticked-promoted-constructors #-}

-- The data structures used during translation
module Mir.Generator
{-
, MirGenerator
, VarMap
, VarInfo (..)
, varInfoRepr
, LabelMap
, AdtMap
, TraitMap (..)
, TraitImpls (..)
, vtableTyRepr
, methodIndex
, vtables
, traitImpls
, FnState (..)
, MirExp (..)
, MirHandle (..)
, HandleMap
, varMap
, labelMap
, handleMap
, traitMap
, MirValue(..)
, valueToExpr
  , getTraitImplementation) 
-}
where

import           Data.Kind(Type)

import qualified Data.List as List
import qualified Data.Maybe as Maybe
import           Data.Map.Strict(Map)
import qualified Data.Map.Strict as Map
import           Data.Text (Text)
import qualified Data.Text as Text
import           Data.Functor.Identity

import           Control.Lens hiding (Empty, (:>), Index, view)
import           Control.Monad

import           Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import           Data.Parameterized.Some
import           Data.Parameterized.Classes
import           Data.Parameterized.Context
import           Data.Parameterized.TraversableFC
import           Data.Parameterized.Peano
import           Data.Parameterized.BoolRepr

import qualified Lang.Crucible.FunctionHandle as FH
import qualified Lang.Crucible.Types as C
import qualified Lang.Crucible.CFG.Generator as G
import qualified Lang.Crucible.CFG.Reg as R
import qualified Lang.Crucible.CFG.Expr as E
import qualified Lang.Crucible.CFG.Core as Core
import qualified Lang.Crucible.Syntax as S



import           Mir.DefId
import           Mir.Mir
import           Mir.MirTy
import           Mir.Intrinsics
import           Mir.GenericOps(ATDict,tySubst,mkSubsts,matchSubsts)
import           Mir.PP

import           Unsafe.Coerce(unsafeCoerce)
import           Debug.Trace
import           GHC.Stack


--------------------------------------------------------------------------------------
-- * Result of translating a collection
--
-- 
data RustModule = RustModule {
         _rmCS    :: CollectionState
       , _rmCFGs  :: Map Text (Core.AnyCFG MIR)
     }


---------------------------------------------------------------------------------

-- | The main data type for values, bundling the term-level
-- type ty along with a crucible expression of type ty
data MirExp s where
    MirExp :: C.TypeRepr ty -> R.Expr MIR s ty -> MirExp s
    

---------------------------------------------------------------------------------

-- * The top-level generator type
-- h state monad token
-- s phantom parameter for CFGs
type MirGenerator h s ret = G.Generator MIR h s FnState ret

--------------------------------------------------------------------------------
-- * Generator state for MIR translation to Crucible
--
-- | Generator state for MIR translation
data FnState (s :: Type)
  = FnState { _varMap     :: !(VarMap s),
              _labelMap   :: !(LabelMap s),                            
              _debugLevel :: !Int,
              _currentFn  :: !Fn,
              _cs         :: !CollectionState,
              _customOps  :: !CustomOpMap,
              _assertFalseOnError :: !Bool              
            }

-- | State about the entire collection used for the translation
data CollectionState 
  = CollectionState {
      _handleMap      :: !HandleMap,
      _vtableMap      :: !VtableMap,
      _staticMap      :: !(Map DefId StaticVar),
      -- | For Enums, gives the discriminant value for each variant.
      _discrMap       :: !(Map AdtName [Integer]),
      _collection     :: !Collection
      }


---------------------------------------------------------------------------
-- ** Custom operations

data CustomOpMap = CustomOpMap
    { _opDefs :: Map ExplodedDefId CustomRHS
    , _fnPtrShimOp :: Ty -> CustomOp
    }

type ExplodedDefId = ([Text], Text, [Text])
data CustomOp      =
    CustomOp (forall h s ret. HasCallStack 
                 => [Ty]       -- ^ argument types
                 -> [MirExp s] -- ^ operand values
                 -> MirGenerator h s ret (MirExp s))
  | CustomMirOp (forall h s ret. HasCallStack
      => [Operand] -> MirGenerator h s ret (MirExp s))
    -- ^ custom operations that dispatch to other functions
    -- i.e. they are essentially the translation of
    -- a function call expression
  | CustomOpExit (forall h s ret.
         [MirExp s]
      -> MirGenerator h s ret Text)
    -- ^ custom operations that don't return
type CustomRHS = Substs -> Maybe CustomOp


---------------------------------------------------------------------------
-- ** Static variables

data StaticVar where
  StaticVar :: C.Closed ty => G.GlobalVar ty -> StaticVar


---------------------------------------------------------------------------
-- *** VarMap

-- | The VarMap maps identifier names to registers (if the id
--   corresponds to a local variable) or an atom (if the id
--   corresponds to a function argument)
type VarMap s = Map Text.Text (Some (VarInfo s))
data VarInfo s tp where
  VarRegister  :: R.Reg s tp -> VarInfo s tp
  VarReference :: R.Reg s (MirReferenceType tp) -> VarInfo s tp
  VarAtom      :: R.Atom s tp -> VarInfo s tp

instance Show (VarInfo s tp) where
    showsPrec d (VarRegister r) = showParen (d > 10) $
        showString "VarRegister " . showsPrec 11 r
    showsPrec d (VarReference r) = showParen (d > 10) $
        showString "VarReference " . showsPrec 11 r
    showsPrec d (VarAtom a) = showParen (d > 10) $
        showString "VarAtom " . showsPrec 11 a
instance ShowF (VarInfo s)


---------------------------------------------------------------------------
-- *** LabelMap

-- | The LabelMap maps identifiers to labels of their corresponding basicblock
type LabelMap s = Map BasicBlockInfo (R.Label s)

---------------------------------------------------------------------------
-- *** HandleMap

-- | The HandleMap maps mir functions to their corresponding function
-- handle. Function handles include the original method name (for
-- convenience) and original Mir type (for trait resolution).
type HandleMap = Map MethName MirHandle

data MirHandle = forall init ret. 
    MirHandle { _mhName       :: MethName
              , _mhSig        :: FnSig
              -- The type of the function handle can include "free variables"
              , _mhHandle     :: FH.FnHandle init ret
              }

---------------------------------------------------------------------------
-- *** VtableMap

-- | The VtableMap maps the name of each vtable to the MirHandles for the
-- vtable shims it contains.
type VtableMap = Map VtableName [MirHandle]


 

-------------------------------------------------------------------------------------------------------

makeLenses ''FnState
makeLenses ''MirHandle
makeLenses ''CollectionState
makeLenses ''RustModule
makeLenses ''CustomOpMap

$(return [])

-------------------------------------------------------------------------------------------------------

-- ** Operations and instances

instance Semigroup RustModule where
  (RustModule cs1 cm1) <> (RustModule cs2 cm2) = RustModule (cs1 <> cs2) (cm1 <> cm2)
instance Monoid RustModule where
  mempty  = RustModule mempty mempty
  mappend = (<>)

instance Semigroup CollectionState  where
  (CollectionState hm1 vm1 sm1 dm1 col1) <> (CollectionState hm2 vm2 sm2 dm2 col2) =
      (CollectionState (hm1 <> hm2) (vm1 <> vm2) (sm1 <> sm2) (dm1 <> dm2) (col1 <> col2))
instance Monoid CollectionState where
  mappend = ((<>))
  mempty  = CollectionState mempty mempty mempty mempty mempty


instance Show (MirExp s) where
    show (MirExp tr e) = (show e) ++ ": " ++ (show tr)

instance Show MirHandle where
    show (MirHandle _nm sig c) =
      show c ++ ":" ++ show sig

instance Pretty MirHandle where
    pretty (MirHandle nm sig _c) =
      text (show nm) <> colon <> pretty sig 


varInfoRepr :: VarInfo s tp -> C.TypeRepr tp
varInfoRepr (VarRegister reg0)  = R.typeOfReg reg0
varInfoRepr (VarReference reg0) =
  case R.typeOfReg reg0 of
    MirReferenceRepr tp -> tp
    _ -> error "impossible: varInfoRepr"
varInfoRepr (VarAtom a) = R.typeOfAtom a

findAdt :: DefId -> MirGenerator h s ret Adt
findAdt name = do
    optAdt <- use $ cs . collection . adts . at name
    case optAdt of
        Just x -> return x
        Nothing -> mirFail $ "unknown ADT " ++ show name

-- | What to do when the translation fails.
mirFail :: String -> MirGenerator h s ret a
mirFail str = do
  b  <- use assertFalseOnError
  db <- use debugLevel
  f  <- use currentFn
  let msg = "Translation error in " ++ show (f^.fname) ++ ": " ++ str
  if b then do
         when (db > 1) $ do
           traceM ("Translation failure: " ++ str)
         when (db > 2) $ do
           traceM (fmt f)
         G.reportError (S.litExpr (Text.pack msg))
       else fail msg


------------------------------------------------------------------------------------
-- extra: Control.Monad.Extra

firstJustM :: Monad m => (a -> m (Maybe b)) -> [a] -> m (Maybe b)
firstJustM f [] = return Nothing
firstJustM f (x:xs) = do
  mx <- f x
  case mx of
    Just y  -> return $ Just y
    Nothing -> firstJustM f xs

firstJust :: (a -> Maybe b) -> [a] -> Maybe b
firstJust f = Maybe.listToMaybe . Maybe.mapMaybe f

-------------------------------------------------------------------------------------------------------
--
-- | Determine whether a function call can be resolved via explicit name bound in the handleMap
--

resolveFn :: HasCallStack => MethName -> Substs -> MirGenerator h s ret (Maybe MirHandle)
resolveFn nm tys = do
  hmap <- use (cs.handleMap)
  case Map.lookup nm hmap of
    Just h@(MirHandle _nm fs fh) -> do
      -- make sure the number of type arguments is consistent with the impl
      -- we don't have to instantiate all of them, but we can't have too many
      if lengthSubsts tys <= length (fs^.fsgenerics) then
        return (Just h)
      else
        return Nothing
    Nothing -> return Nothing

---------------------------------------------------------------------------------------------------

-- Now that intrinsics are monomorphized, the `Substs` is always empty.  The
-- `DefId` refers to an entry in the `intrinsics` map, which contains the
-- original `DefId` and `Substs` used to produce the monomorphized instance.
-- Those are what we look up in `customOps`.
resolveCustom :: DefId -> Substs -> MirGenerator h s ret (Maybe CustomOp)
resolveCustom instDefId _substs = do
    optIntr <- use $ cs . collection . intrinsics . at instDefId
    case optIntr of
        Nothing -> return Nothing
        Just intr -> case intr ^. intrInst . inKind of
            IkFnPtrShim ty -> do
                f <- use $ customOps . fnPtrShimOp
                return $ Just $ f ty
            _ -> do
                let origDefId = intr ^. intrInst . inDefId
                let origSubsts = intr ^. intrInst . inSubsts
                let edid = (map fst (did_path origDefId),
                        fst (did_name origDefId),
                        map fst (did_extra origDefId))
                optOp <- use $ customOps . opDefs .  at edid
                case optOp of
                    Nothing -> return Nothing
                    Just f -> do
                        return $ f origSubsts

---------------------------------------------------------------------------------------------------


-----------------------------------------------------------------------
-- ** MIR intrinsics Generator interaction

newMirRef ::
  C.TypeRepr tp ->
  MirGenerator h s ret (R.Expr MIR s (MirReferenceType tp))
newMirRef tp = G.extensionStmt (MirNewRef tp)

dropMirRef ::
  R.Expr MIR s (MirReferenceType tp) ->
  MirGenerator h s ret ()
dropMirRef refExp = void $ G.extensionStmt (MirDropRef refExp)

readMirRef ::
  C.TypeRepr tp ->
  R.Expr MIR s (MirReferenceType tp) ->
  MirGenerator h s ret (R.Expr MIR s tp)
readMirRef tp refExp = G.extensionStmt (MirReadRef tp refExp)

writeMirRef ::
  R.Expr MIR s (MirReferenceType tp) ->
  R.Expr MIR s tp ->
  MirGenerator h s ret ()
writeMirRef ref x = void $ G.extensionStmt (MirWriteRef ref x)

subanyRef ::
  C.TypeRepr tp ->
  R.Expr MIR s (MirReferenceType C.AnyType) ->
  MirGenerator h s ret (R.Expr MIR s (MirReferenceType tp))
subanyRef tpr ref = G.extensionStmt (MirSubanyRef tpr ref)

subfieldRef ::
  C.CtxRepr ctx ->
  R.Expr MIR s (MirReferenceType (C.StructType ctx)) ->
  Index ctx tp ->
  MirGenerator h s ret (R.Expr MIR s (MirReferenceType tp))
subfieldRef ctx ref idx = G.extensionStmt (MirSubfieldRef ctx ref idx)

subvariantRef ::
  C.CtxRepr ctx ->
  R.Expr MIR s (MirReferenceType (RustEnumType ctx)) ->
  Index ctx tp ->
  MirGenerator h s ret (R.Expr MIR s (MirReferenceType tp))
subvariantRef ctx ref idx = G.extensionStmt (MirSubvariantRef ctx ref idx)

subindexRef ::
  C.TypeRepr tp ->
  R.Expr MIR s (MirReferenceType (C.VectorType tp)) ->
  R.Expr MIR s UsizeType ->
  MirGenerator h s ret (R.Expr MIR s (MirReferenceType tp))
subindexRef tp ref idx = G.extensionStmt (MirSubindexRef tp ref idx)

subjustRef ::
  C.TypeRepr tp ->
  R.Expr MIR s (MirReferenceType (C.MaybeType tp)) ->
  MirGenerator h s ret (R.Expr MIR s (MirReferenceType tp))
subjustRef tp ref = G.extensionStmt (MirSubjustRef tp ref)

-----------------------------------------------------------------------



vectorSnoc ::
  C.TypeRepr tp ->
  R.Expr MIR s (C.VectorType tp) ->
  R.Expr MIR s tp ->
  MirGenerator h s ret (R.Expr MIR s (C.VectorType tp))
vectorSnoc tp v e = G.extensionStmt $ VectorSnoc tp v e

vectorInit ::
  C.TypeRepr tp ->
  R.Expr MIR s (C.VectorType tp) ->
  MirGenerator h s ret (R.Expr MIR s (C.VectorType tp))
vectorInit tp v = G.extensionStmt $ VectorInit tp v

vectorLast ::
  C.TypeRepr tp ->
  R.Expr MIR s (C.VectorType tp) ->
  MirGenerator h s ret (R.Expr MIR s (C.MaybeType tp))
vectorLast tp v = G.extensionStmt $ VectorLast tp v

vectorConcat ::
  C.TypeRepr tp ->
  R.Expr MIR s (C.VectorType tp) ->
  R.Expr MIR s (C.VectorType tp) ->
  MirGenerator h s ret (R.Expr MIR s (C.VectorType tp))
vectorConcat tp v e = G.extensionStmt $ VectorConcat tp v e

vectorTake ::
  C.TypeRepr tp ->
  R.Expr MIR s (C.VectorType tp) ->
  R.Expr MIR s C.NatType ->
  MirGenerator h s ret (R.Expr MIR s (C.VectorType tp))
vectorTake tp v e = G.extensionStmt $ VectorTake tp v e

vectorDrop ::
  C.TypeRepr tp ->
  R.Expr MIR s (C.VectorType tp) ->
  R.Expr MIR s C.NatType ->
  MirGenerator h s ret (R.Expr MIR s (C.VectorType tp))
vectorDrop tp v e = G.extensionStmt $ VectorDrop tp v e




--  LocalWords:  ty ImplementTrait ctx vtable idx runtime struct
--  LocalWords:  vtblToStruct
