module Unison.Merge.Unconflicts
  ( Unconflicts (..),
    empty,
    apply,
    soloDeletedNames,
    soloUpdatedNames,
  )
where

import Data.Map.Strict qualified as Map
import Unison.Merge.TwoWay (TwoWay)
import Unison.Merge.TwoWayI (TwoWayI (..))
import Unison.Merge.TwoWayI qualified as TwoWayI
import Unison.Name (Name)
import Unison.Prelude hiding (empty)

data Unconflicts v = Unconflicts
  { adds :: !(TwoWayI (Map Name v)),
    deletes :: !(TwoWayI (Map Name v)),
    updates :: !(TwoWayI (Map Name v))
  }
  deriving stock (Foldable, Functor, Generic)

empty :: Unconflicts v
empty =
  Unconflicts x x x
  where
    x = TwoWayI Map.empty Map.empty Map.empty

-- | Apply unconflicts to a namespace.
apply :: forall v. Unconflicts v -> Map Name v -> Map Name v
apply unconflicts =
  applyDeletes . applyUpdates . applyAdds
  where
    applyAdds :: Map Name v -> Map Name v
    applyAdds =
      Map.union (fold unconflicts.adds)

    applyUpdates :: Map Name v -> Map Name v
    applyUpdates =
      Map.union (fold unconflicts.updates)

    applyDeletes :: Map Name v -> Map Name v
    applyDeletes =
      (`Map.withoutKeys` foldMap Map.keysSet unconflicts.deletes)

soloDeletedNames :: Unconflicts v -> TwoWay (Set Name)
soloDeletedNames =
  fmap Map.keysSet . TwoWayI.forgetBoth . view #deletes

soloUpdatedNames :: Unconflicts v -> TwoWay (Set Name)
soloUpdatedNames =
  fmap Map.keysSet . TwoWayI.forgetBoth . view #updates
