# alembic-sqlite-carp

an [alembic](https://github.com/cyberwitchery/alembic) external adapter that
stores ir objects in a sqlite database. written in
[carp](https://github.com/carp-lang/Carp), a statically typed lisp that compiles
to c (and that i happen to be a co-maintainer of).

it is a working backend (read/write/`ensure_schema`), not a demo, and doubles as a
crossover example: alembic's external protocol spoken by a non-rust binary.

## what it does

sqlite becomes a generic, vendor-neutral alembic backend. every ir object lives
in one table:

```sql
CREATE TABLE alembic_objects (
  backend_id INTEGER PRIMARY KEY AUTOINCREMENT,
  type_name  TEXT NOT NULL,
  key_json   TEXT NOT NULL,
  attrs_json TEXT NOT NULL,
  UNIQUE(type_name, key_json)
);
```

the rowid is the backend id alembic tracks in its state. one table holds any
type, so no per-type schema generation is needed. attrs are stored and returned
verbatim, including relationship refs, which the engine hands the adapter as the
target object's UID string (not a resolved foreign key). because desired and
observed both carry UIDs, the plan still converges. an adapter targeting a real
backend would resolve those UIDs to its own ids using the `state.mappings` that
ride along in every request.

## the protocol

an external adapter is a standalone binary the alembic cli spawns as a
subprocess: it reads a single json request on stdin and writes a single json
response on stdout. three methods (protocol v1):

- `read` — `SELECT` the requested types and return them as observed objects so
  the engine can diff against the desired inventory.
- `write` — apply create/update/delete ops in one transaction (rolled back if any
  op fails). create `INSERT`s and returns the new rowid as `backend_id`; update
  and delete locate the row by the `backend_id` carried in state, falling back to
  `(type_name, key)` when state has no mapping yet.
- `ensure_schema` — creates the storage table. returns an empty provision report;
  the table is also created on every connection, so read and write work without a
  prior `ensure_schema`.

see the alembic
[external adapter docs](https://github.com/cyberwitchery/alembic/blob/main/docs/external-adapters.md)
for the full request/response shapes.

## build

```bash
make
make optimize # optional optimizations
```

or directly:

```bash
carp -b alembic-sqlite.carp
```

## run

wire it into alembic as an external backend using
[`examples/backend.yaml`](examples/backend.yaml):

```bash
alembic plan  --backend external --backend-config examples/backend.yaml \
  -f inventory.yaml -o plan.json
alembic apply --backend external --backend-config examples/backend.yaml \
  -p plan.json
```

the db path comes from the `setup:` block in that config (`path:`, default
`alembic.db`).

## tests

```bash
carp -x test/adapter.carp
bash test/e2e.sh # e2e: the compiled binary over stdin/stdout
```

the unit suite drives the handlers in-process (create, read, update, delete,
idempotent no-ops, error paths). the e2e script exercises the real process
boundary against a temp sqlite file. ci runs both on linux and macos via
[`carpentry-org/setup-carp`](https://github.com/carpentry-org/setup-carp).

`test/e2e-alembic.sh` has the real alembic cli spawn the adapter and converge an
inventory (plan/apply, idempotent re-plan, update, delete). locally it needs the
alembic cli (`$ALEMBIC` or `../alembic/target/*/alembic-cli`). ci runs it too, in
a separate linux-only job that `cargo install`s `alembic-cli` from crates.io (the
compiled binary is cached, so it builds once, not every run).

<hr/>

have fun!
