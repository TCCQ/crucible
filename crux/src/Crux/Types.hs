{-# Language DeriveFunctor, RankNTypes, ConstraintKinds, TypeFamilies, ScopedTypeVariables, GADTs #-}
module Crux.Types where

import qualified Control.Lens as L
import           Data.Parameterized.Map (MapF)
import           Data.Sequence (Seq)
import           Data.Text ( Text )
import           Data.Void
import           Prettyprinter

import           What4.Expr (GroundValue)
import           What4.Interface (Pred)
import           What4.ProgramLoc

import           Lang.Crucible.Backend
import           Lang.Crucible.Simulator
import           Lang.Crucible.Types

-- | A constraint on crucible personality types that requires them to contain a 'Model'
--
-- The personality is extra data carried around by the symbolic execution engine
-- for frontend-specific purposes.  Typically, the personality is consulted from
-- overrides and can allow extensible data sharing between overrides.  Crux
-- requires that the personality include at least a 'Model', which it will
-- populate based on SMT solver results.
class HasModel personality where
  personalityModel :: L.Lens' (personality sym) (Model sym)

-- | This instance handles the common case where a crux frontend does not need
-- any special instantiation of the personality parameter, and so can just use a
-- 'Model' directly.
instance HasModel Model where
  personalityModel = \f a -> fmap id (f a)

-- | A simulator context
type SimCtxt personality sym p = SimContext (personality sym) sym p

-- | The instance of the override monad we use,
-- when we don't care about the context of the surrounding function.
type OverM personality sym ext a =
  forall r args ret.
  OverrideSim
    (personality sym)  -- Extra data available in overrides (frontend-specific)
    sym                -- The symbolic backend (usually a what4 ExprBuilder in some form)
    ext                -- The Crucible syntax extension for the target language
    r
    args
    ret
    a

-- | This is the instance of the 'OverrideSim' monad that we use.
type Fun personality sym ext args ret =
  forall r.
  OverrideSim
    (personality sym)
    sym                                    -- the backend
    ext
    r
    args
    ret
    (RegValue sym ret)

-- NEW: the result of the simulation function, which hides the 'ext'
data Result personality sym where
  Result :: (ExecResult (personality sym) sym ext (RegEntry sym UnitType)) -> Result personality sym

--- From Goal


data ProcessedGoals =
  ProcessedGoals { totalProcessedGoals :: !Integer
                 , provedGoals :: !Integer
                 , disprovedGoals :: !Integer
                 , incompleteGoals :: !Integer
                 }

data ProofResult a
   = Proved [a]
   | NotProved (Doc Void) (Maybe ModelView)
     -- ^ The first argument is an explanation of the failure and
     -- counter example as provided by the Explainer (if any) and the
     -- second maybe a model for the counter-example.
 deriving (Functor)

type LPred sym   = LabeledPred (Pred sym)

data ProvedGoals a =
    AtLoc ProgramLoc (Maybe ProgramLoc) (ProvedGoals a)
  | Branch (ProvedGoals a) (ProvedGoals a)
  | Goal [(CrucibleAssumption (), Doc Void )]
         (SimError, Doc Void) Bool (ProofResult a)
    -- ^ Keeps only the explanations for the relevant assumptions.
    --
    --   * The array of (AssumptionReason,String) is the set of
    --     assumptions for this Goal.
    --
    --   * The (SimError,String) is information about the failure,
    --     with the specific SimError (Lang.Crucible.Simulator) and a
    --     string representation of the Crucible term that encountered
    --     the error.
    --
    --   * The 'Bool' (third argument) indicates if the goal is
    --     trivial (i.e., the assumptions are inconsistent)


data ProgramCompleteness
 = ProgramComplete
 | ProgramIncomplete
 deriving (Eq,Ord,Show)



data CruxSimulationResult =
  CruxSimulationResult
  { cruxSimResultCompleteness :: ProgramCompleteness
  , cruxSimResultGoals        :: Seq (ProcessedGoals, ProvedGoals (Either (CrucibleAssumption ()) SimError))
  }


-- From Model

-- | SMT model organized by crucible type. I.e., each
-- crucible type is associated with the list of entries
-- (i.e. named, possibly still symbolic, RegValues) at that
-- type for the given model, used to describe the conditions
-- under which an SMT query is satisfiable. N.B., because
-- the values may still be symbolic, they must be evaluated
-- before they are grounded (e.g., see the `evalModel` and
-- `groundEval` functions from Crux.Model and
-- What4.Expr.GroundEval, which are used to construct the
-- ModelView datatype described below).
newtype Model sym   = Model (MapF BaseTypeRepr (Vars sym))

-- | A list of named (possibly still symbolic) RegValues of
-- the same type (used to describe SMT models -- see the
-- Model datatype).
newtype Vars sym ty = Vars [ Entry (RegValue sym (BaseToType ty)) ]

-- | A list of named GroundValues of the same type (used to
-- report SMT models in a portable way -- see the ModelView
-- datatype).
newtype Vals ty     = Vals [ Entry (GroundValue ty) ]

-- | A named value of type `ty` with a program
-- location. Used to describe and report models from SMT
-- queries (see Model and ModelView datatypes).
data Entry ty       = Entry { entryName :: String
                            , entryLoc :: ProgramLoc
                            , entryValue :: ty
                            }

-- | A portable/concrete view of a model's contents, organized by
-- crucible type. I.e., each crucible type is associated
-- with the list of entries (i.e. named GroundValues) at
-- that type for the given model, used to describe the
-- conditions under which an SMT query is satisfiable.
newtype ModelView = ModelView { modelVals :: MapF BaseTypeRepr Vals }

----------------------------------------------------------------------
-- Various things that can be logged/output

-- | Specify some general text that should be presented (to the user).
data SayWhat = SayWhat SayLevel Text Text  -- ^ fields are: Level From Message
             | SayMore SayWhat SayWhat
             | SayNothing

-- | Specify the verbosity/severity level of a message.  These are in
-- ordinal order for possible filtering, and higher levels may be sent
-- to a different location (e.g. stderr v.s. stdout).
data SayLevel = Noisily | Simply | OK | Warn | Fail deriving (Eq, Ord)
