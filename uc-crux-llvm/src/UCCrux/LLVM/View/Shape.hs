{-
Module           : UCCrux.LLVM.View.Shape
Description      : See "UCCrux.LLVM.View".
Copyright        : (c) Galois, Inc 2022
License          : BSD3
Maintainer       : Langston Barrett <langston@galois.com>
Stability        : provisional
-}

{-# LANGUAGE GADTs #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StrictData #-}
{-# LANGUAGE TemplateHaskell #-}

module UCCrux.LLVM.View.Shape
  ( ViewShapeError,
    ppViewShapeError,
    PtrShapeView(..),
    ptrShapeView,
    viewPtrShape,
    ShapeView(..),
    shapeView,
    viewShape,
  )
where

import           Control.Monad (when)
import qualified Data.Aeson as Aeson
import qualified Data.Aeson.TH as Aeson.TH
import           Data.Foldable (toList)
import           Data.List.NonEmpty (NonEmpty, nonEmpty)
import           Data.Sequence (Seq)
import           Data.Vector (Vector)
import qualified Data.Vector as Vec
import           GHC.Generics (Generic)
import           Numeric.Natural (Natural)

import           Prettyprinter (Doc)

import qualified Data.Parameterized.Context as Ctx
import qualified Data.Parameterized.NatRepr as NatRepr
import           Data.Parameterized.TraversableFC (toListFC)
import           Data.Parameterized.TraversableFC.WithIndex (itraverseFC)
import qualified Data.Parameterized.Vector as PVec

import           UCCrux.LLVM.Errors.Panic (panic)
import           UCCrux.LLVM.FullType.Type (FullTypeRepr(..), ModuleTypes, asFullType)
import           UCCrux.LLVM.Shape (PtrShape(..), Shape(..))

data ViewShapeError e
  = TagError e
  | TypeMismatch
  | StructLengthMismatch
  | VectorLengthMismatch !Natural !Int
  deriving (Eq, Ord, Show)

ppViewShapeError :: (e -> Doc ann) -> ViewShapeError e -> Doc ann
ppViewShapeError err =
  \case
    TagError e -> err e
    TypeMismatch -> "Type mismatch"
    StructLengthMismatch -> "Struct length mismatch"
    VectorLengthMismatch{} -> "Vector length mismatch"

-- Helper, not exported
liftErr :: Either e a -> Either (ViewShapeError e) a
liftErr =
  \case
    Left e -> Left (TagError e)
    Right v -> Right v

data PtrShapeView vtag
  = ShapeUnallocatedView
  | ShapeAllocatedView Int
  | ShapeInitializedView (Seq (ShapeView vtag))
  deriving (Eq, Generic, Ord, Show)

ptrShapeView ::
  (forall t. tag t -> vtag) ->
  PtrShape m tag ft ->
  PtrShapeView vtag
ptrShapeView tag =
  \case
    ShapeUnallocated -> ShapeUnallocatedView
    ShapeAllocated n -> ShapeAllocatedView n
    ShapeInitialized s -> ShapeInitializedView (fmap (shapeView tag) s)

viewPtrShape ::
  ModuleTypes m ->
  -- | How to decode un-parameterized tags into parameterized tags.
  --
  -- This decoding is allowed to fail (for instance, if the type of the
  -- 'FullTypeRepr' doesn't match the @vtag@ datum), this failure is propagated
  -- up and out into the 'ViewShapeError'.
  (forall t. FullTypeRepr m t -> vtag -> Either e (tag t)) ->
  FullTypeRepr m ft ->
  PtrShapeView vtag ->
  Either (ViewShapeError e) (PtrShape m tag ft)
viewPtrShape mts tag ft =
  \case
    ShapeUnallocatedView -> Right ShapeUnallocated
    ShapeAllocatedView n -> Right (ShapeAllocated n)
    ShapeInitializedView s ->
      ShapeInitialized <$> traverse (viewShape mts tag ft) s

data ShapeView vtag
  = ShapeIntView vtag
  | ShapeFloatView vtag
  | ShapePtrView vtag (PtrShapeView vtag)
  | ShapeFuncPtrView vtag
  | ShapeOpaquePtrView vtag
  | ShapeArrayView vtag (NonEmpty (ShapeView vtag))
  | ShapeUnboundedArrayView vtag (Seq (ShapeView vtag))
  | ShapeStructView vtag (Vector (ShapeView vtag))
  deriving (Eq, Generic, Ord, Show)

shapeView ::
  (forall t. tag t -> vtag) ->
  Shape m tag ft ->
  ShapeView vtag
shapeView tag =
  \case
    ShapeInt t -> ShapeIntView (tag t)
    ShapeFloat t -> ShapeFloatView (tag t)
    ShapePtr t ps -> ShapePtrView (tag t) (ptrShapeView tag ps)
    ShapeFuncPtr t -> ShapeFuncPtrView (tag t)
    ShapeOpaquePtr t -> ShapeOpaquePtrView (tag t)
    ShapeArray t _nr vec ->
      case nonEmpty (map (shapeView tag) (toList vec)) of
        Nothing -> panic "shapeView" ["Empty vector"]
        Just vec' -> ShapeArrayView (tag t) vec'
    ShapeUnboundedArray t s ->
      ShapeUnboundedArrayView (tag t) (fmap (shapeView tag) s)
    ShapeStruct t fields ->
      ShapeStructView (tag t) (Vec.fromList (toListFC (shapeView tag) fields))

viewShape ::
  forall m e vtag tag ft.
  ModuleTypes m ->
  -- | How to decode un-parameterized tags into parameterized tags.
  --
  -- This decoding is allowed to fail (for instance, if the type of the
  -- 'FullTypeRepr' doesn't match the @vtag@ datum), this failure is propagated
  -- up and out into the 'ViewShapeError'.
  (forall t. FullTypeRepr m t -> vtag -> Either e (tag t)) ->
  FullTypeRepr m ft ->
  ShapeView vtag ->
  Either (ViewShapeError e) (Shape m tag ft)
viewShape mts tag ft vshape =
  case (ft, vshape) of
    (FTIntRepr{}, ShapeIntView vtag) ->
      do t <- getTag vtag
         return (ShapeInt t)
    (FTFloatRepr{}, ShapeFloatView vtag) ->
      do t <- getTag vtag
         return (ShapeFloat t)
    (FTPtrRepr pt, ShapePtrView vtag vptr) ->
      do t <- getTag vtag
         sub <- viewPtrShape mts tag (asFullType mts pt) vptr
         return (ShapePtr t sub)
    (FTVoidFuncPtrRepr{}, ShapeFuncPtrView vtag) ->
      do t <- getTag vtag
         return (ShapeFuncPtr t)
    (FTNonVoidFuncPtrRepr{}, ShapeFuncPtrView vtag) ->
      do t <- getTag vtag
         return (ShapeFuncPtr t)
    (FTArrayRepr n ftElems, ShapeArrayView vtag velems) ->
      do t <- getTag vtag
         subs <- traverse (viewShape mts tag ftElems) velems
         case PVec.fromList n (toList subs) of
           Nothing ->
             Left (VectorLengthMismatch (NatRepr.natValue n) (length velems))
           Just vec -> return (ShapeArray t n vec)
    (FTUnboundedArrayRepr ftElems, ShapeUnboundedArrayView vtag velems) ->
      do t <- getTag vtag
         subs <- traverse (viewShape mts tag ftElems) velems
         return (ShapeUnboundedArray t subs)
    (FTStructRepr _ ftFields, ShapeStructView vtag vfields) ->
      do t <- getTag vtag
         let viewField ::
               forall ctx t.
               Ctx.Index ctx t ->
               FullTypeRepr m t ->
               Either (ViewShapeError e) (Shape m tag t)
             viewField i fieldType =
               case vfields Vec.!? Ctx.indexVal i of
                 Just vfield -> viewShape mts tag fieldType vfield
                 Nothing -> Left StructLengthMismatch
         fields <- itraverseFC viewField ftFields
         check
           (length vfields > Ctx.sizeInt (Ctx.size ftFields))
           StructLengthMismatch
         return (ShapeStruct t fields)
    (FTOpaquePtrRepr{}, ShapeOpaquePtrView vtag) ->
      do t <- getTag vtag
         return (ShapeOpaquePtr t)
    _ -> Left TypeMismatch
  where
    check cond err = when cond (Left err)
    getTag vtag = liftErr (tag ft vtag)

$(Aeson.TH.deriveJSON Aeson.defaultOptions ''PtrShapeView)
$(Aeson.TH.deriveJSON Aeson.defaultOptions ''ShapeView)
