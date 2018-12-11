{-# LANGUAGE GADTs, TypeOperators #-}

module Control.Matching
  ( -- | Core types
    Matcher
  , TermMatcher
  -- | Combinators
  , target
  , purely
  , ensure
  -- | Predicate filtering
  , refine
  , only
  -- | Projecting terms and sums
  , narrow
  , narrowF
  , enter
  -- | Useful matchers
  , mhead
  , mjust
  -- | Running matchers
  , matchRecursively
  , match
  -- | Reexports from Control.Category
  , (>>>)
  , (<<<)
  ) where

import Prelude hiding (id, (.))
import Prologue hiding (First, project)

import Control.Category
import Control.Arrow

import Data.Sum
import Data.Term

-- | A @Matcher t a@ is a parser over some 'Recursive' and
--   'Corecursive' type @t@, yielding values of type @a@.
--
-- Matching operations are implicitly recursive: when you run a
-- 'Matcher', it is applied bottom-up. If a matching operation
-- returns a value, it is assumed to have succeeded. You use the
-- 'guard', 'narrow', and 'ensure' functions to control whether a
-- given datum is matched. The @t@ datum matched by a matcher is
-- immutable; if you need to modify values during a match operation,
-- consider using Control.Rewriting.
data Matcher t a where
  -- TODO: Choice is inflexible and slow. A Sum over fs can be queried for its index, and we can build a jump table over that.
  -- We can copy NonDet to have fair conjunction or disjunction.
  Choice :: Matcher t a -> Matcher t a -> Matcher t a
  Target :: Matcher t t
  Empty  :: Matcher t a
  Comp   :: Matcher b c -> Matcher a b -> Matcher a c
  Split  :: Matcher b c -> Matcher b' c' -> Matcher (b, b') (c, c')
  -- We could have implemented this by changing the semantics of how Then is interpreted, but that would make Then and Sequence inconsistent.
  Match  :: (t -> Maybe u) -> Matcher u a -> Matcher t a
  Pure   :: a -> Matcher t a
  Then   :: Matcher t b -> (b -> Matcher t a) -> Matcher t a

-- | A convenience alias for matchers that both target and return 'Term' values.
type TermMatcher fs ann = Matcher (Term (Sum fs) ann) (Term (Sum fs) ann)

instance Functor (Matcher t) where
  fmap = liftA

instance Applicative (Matcher t) where
  pure   = Pure
  -- We can add a Sequence constructor to optimize this when we need.
  (<*>)  = ap

instance Alternative (Matcher t) where
  empty = Empty
  (<|>) = Choice

instance Monad (Matcher t) where
  (>>=) = Then

-- | Matchers are generally composed left-to-right with '>>>'.
instance Category Matcher where
  id  = Target
  (.) = Comp

instance Arrow Matcher where
  (***) = Split
  arr f = fmap f target

-- | 'target' extracts the 't' that a given 'Matcher' is operating upon.
--   Similar to a reader monad's 'ask' function. This is an alias for 'id'
target :: Matcher t t
target = id

-- | 'ensure' succeeds iff the provided predicate function returns true when applied to the matcher's 'target'.
-- If it succeeds, it returns the matcher's 'target'.
ensure :: (t -> Bool) -> Matcher t t
ensure f = target >>= \c -> c <$ guard (f c)

-- | Promote a pure function to a 'Matcher'. An alias for 'arr'.
purely :: (a -> b) -> Matcher a b
purely = arr

-- | 'refine' takes a modification function and a new matcher action
-- the target parameter of which is the result of the modification
-- function. If the modification function returns 'Just' when applied
-- to the current 'target', the given matcher is executed with the
-- result of that 'Just' as the new target; if 'Nothing' is returned,
-- the action fails.
--
-- This is the lowest-level combinator for applying a predicate function
-- to a matcher. In practice, you'll generally use the 'enter' and 'narrow'
-- combinators to iterate on recursive 'Term' values.
refine :: (t -> Maybe u) -> Matcher u a -> Matcher t a
refine = Match

-- | An alias for the common pattern of @match f id@.
only :: (t -> Maybe u) -> Matcher t u
only f = Match f Target

-- | The 'enter' combinator is the primary interface for creating
-- matchers that 'project' their internal 'Term' values into some
-- constituent type. Given a function from a constituent type @f@
-- @need p@ succeeds if the provided term can be projected into
-- an @f@, then applies the @p@ function.
enter :: ( f :< fs
         , term ~ Term (Sum fs) ann
         )
     => (f term -> b)
     -> Matcher term b
enter f = Match (fmap f . projectTerm) target

-- | 'narrow' projects the given 'Term' of 'Sum's into a constituent member
-- of that 'Sum', failing if the target cannot be thus projected.
narrow :: (f :< fs) => Matcher (Term (Sum fs) ann) (f (Term (Sum fs) ann))
narrow = purely projectTerm >>= foldMapA pure

-- | Like 'narrow', but it returns the result of the projection in a
-- 'TermF'. Useful for returning a matched node after ensuring its
-- contents are projectable and valid, e.g @narrowF <* a >:: b >>>
-- ensure f@, without losing valuable annotation info.
narrowF :: (f :< fs, term ~ Term (Sum fs) ann)
        => Matcher term (TermF f ann term)
narrowF = do
  (Term (In ann syn)) <- target
  case project syn of
    Just fs -> pure (In ann fs)
    Nothing -> empty

-- | Matches on the head of the input list. Fails if the list is empty.
--
-- @mhead = only listToMaybe@
mhead :: Matcher [a] a
mhead = only listToMaybe

-- | Matches on 'Just' values.
--
-- @mjust = only id@
mjust :: Matcher (Maybe a) a
mjust = only id


-- | The entry point for executing matchers.
--   The Alternative parameter should be specialized by the calling context. If you want a single
--   result, specialize it to 'Maybe'; if you want a list of all terms and subterms matched by the
--   provided 'Matcher' action, specialize it to '[]'.
matchRecursively :: (Alternative m, Monad m, Corecursive t, Recursive t, Foldable (Base t))
                 => Matcher t a
                 -> t
                 -> m a
matchRecursively m = para (paraMatcher m)

paraMatcher :: (Alternative m, Monad m, Corecursive t, Foldable (Base t)) => Matcher t a -> RAlgebra (Base t) t (m a)
paraMatcher m t = match (embedTerm t) m <|> foldMapA snd t

-- | Run one step of a 'Matcher' computation. Look at 'matchRecursively' if you want something
-- that folds over subterms.
match :: (Alternative m, Monad m) => t -> Matcher t a -> m a
match t (Choice a b) = match t a <|> match t b
match t Target       = pure t
match t (Match f m)  = foldMapA (`match` m) (f t)
match t (Comp g f)   = match t f >>= \x -> match x g
match _ (Pure a)     = pure a
match _ Empty        = empty
match t (Then m f)   = match t m >>= match t . f
match t (Split f g)  = match t id >>= \(a, b) -> (,) <$> match a f <*> match b g