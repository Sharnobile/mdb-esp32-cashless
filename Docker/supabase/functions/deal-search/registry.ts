// Built-in DealSource providers, keyed by their stable id.
//
// To add a built-in provider:
//   1. Create Docker/supabase/functions/_shared/providers/deal-source/<id>.ts
//      that exports `provider: DealSourceProvider`.
//   2. Add the import + registry entry below.
//   3. Add tests under the same path with `.test.ts`.
//   4. Document in docs/extension-points/deal-source.md.

import type { DealSourceProvider } from '../_shared/providers/deal-source.ts'
import { provider as marktguru } from '../_shared/providers/deal-source/marktguru.ts'

export const builtinProviders: Record<string, DealSourceProvider> = {
  marktguru,
}
