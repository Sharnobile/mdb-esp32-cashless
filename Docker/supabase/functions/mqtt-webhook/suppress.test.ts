// Use the same std-assert specifier the repo's existing mdb-log.test.ts uses.
import { assertEquals } from "jsr:@std/assert";
import { decideSuppress, SUPPRESS_WINDOW_MS } from "./suppress.ts";

const T = 1_700_000_000_000; // fixed base ms

Deno.test("not suppressed when time_uncertain is false (even with a match)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: false, createdAtMs: T }, [{ id: "a", createdAtMs: T }]),
    null,
  );
});

Deno.test("suppressed (returns matched id) when time_uncertain + candidate within window", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + 5_000 }]),
    "a",
  );
});

Deno.test("not suppressed when the only candidate is outside the window", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "a", createdAtMs: T + SUPPRESS_WINDOW_MS + 1 }]),
    null,
  );
});

Deno.test("not suppressed when there are no candidates", () => {
  assertEquals(decideSuppress({ timeUncertain: true, createdAtMs: T }, []), null);
});

Deno.test("window is symmetric (candidate slightly before also matches)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "b", createdAtMs: T - 10_000 }]),
    "b",
  );
});

Deno.test("suppressed at exactly the window boundary (<= is inclusive)", () => {
  assertEquals(
    decideSuppress({ timeUncertain: true, createdAtMs: T }, [{ id: "c", createdAtMs: T + SUPPRESS_WINDOW_MS }]),
    "c",
  );
});
