// catch, catchTag (one tag, several tags, and orElse), catchTags, mapError, and
// orElseSucceed recover typed failures by their _tag.
import { Data, Effect } from "effect";

class NotFound extends Data.TaggedError("NotFound")<{ readonly id: string }> {}
class Forbidden extends Data.TaggedError("Forbidden")<{ readonly user: string }> {}
class Timeout extends Data.TaggedError("Timeout")<{ readonly ms: number }> {}

const load = (key: string): Effect.Effect<string, NotFound | Forbidden | Timeout> => {
  if (key === "missing") return Effect.fail(new NotFound({ id: key }));
  if (key === "secret") return Effect.fail(new Forbidden({ user: "guest" }));
  if (key === "slow") return Effect.fail(new Timeout({ ms: 30 }));
  return Effect.succeed(`value of ${key}`);
};

const show = (label: string, effect: Effect.Effect<unknown, unknown>) => {
  const result = Effect.runSync(Effect.result(effect));
  if (result._tag === "Success") {
    console.log(label, "->", result.success);
  } else {
    const failure = result.failure as { _tag?: string };
    console.log(label, "-> failure", failure._tag ?? failure);
  }
};

show(
  "catch",
  Effect.catch(load("missing"), (error) => Effect.succeed(`recovered ${error._tag}`)),
);
show("catch data-last", load("secret").pipe(Effect.catch((error) => Effect.succeed(error._tag))));
show(
  "catchTag",
  load("missing").pipe(Effect.catchTag("NotFound", (error) => Effect.succeed(`no ${error.id}`))),
);
show(
  "catchTag other tag",
  load("secret").pipe(Effect.catchTag("NotFound", () => Effect.succeed("unused"))),
);
show(
  "catchTag several",
  load("slow").pipe(
    Effect.catchTag(["NotFound", "Timeout"], (error) => Effect.succeed(`handled ${error._tag}`)),
  ),
);
show(
  "catchTag orElse",
  load("secret").pipe(
    Effect.catchTag(
      "NotFound",
      () => Effect.succeed("unused"),
      (error) => Effect.succeed(`orElse ${error._tag}`),
    ),
  ),
);
show(
  "catchTag data-first",
  Effect.catchTag(load("missing"), "NotFound", (error) => Effect.succeed(error.id.length)),
);
show(
  "catchTags",
  load("secret").pipe(
    Effect.catchTags({
      NotFound: (error) => Effect.succeed(`missing ${error.id}`),
      Forbidden: (error) => Effect.succeed(`forbidden for ${error.user}`),
    }),
  ),
);
show(
  "catchTags unmatched",
  load("slow").pipe(Effect.catchTags({ NotFound: () => Effect.succeed("unused") })),
);
show(
  "catchTags success",
  load("open").pipe(Effect.catchTags({ NotFound: () => Effect.succeed("unused") })),
);
show("mapError", load("missing").pipe(Effect.mapError((error) => `mapped ${error._tag}`)));
show(
  "orElseSucceed",
  load("slow").pipe(Effect.orElseSucceed((error) => `fallback after ${error._tag}`)),
);
show(
  "catch rethrows",
  load("missing").pipe(Effect.catch((error) => Effect.fail(`again ${error._tag}`))),
);
show(
  "plain failure",
  Effect.fail("not tagged").pipe(Effect.catchTag("NotFound" as never, () => Effect.succeed(1))),
);
