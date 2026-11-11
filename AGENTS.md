# Repository scope

- Canonical database design only: MySQL 8.4, Node.js/Express backend using mysql2.
- Do not add an Express application, ORM or ASP.NET/Identity dependency unless the user asks.
- No legacy DB migrations: the user is designing a new schema.
- SQL catalogs use mysql2 named placeholders (:name), parameters are bound.
- Do not persist imported contact people, email/phone blocks, raw source API responses or provider credentials.
- The user approved permanent-job search without personal availability calendars.
- Validation: npm ci then npm test against isolated MySQL 8.4; see BACKEND_HANDOFF.md.
- Backend app unit/integration tests: Vitest + Supertest in the backend repo. QA may test HTTP externally with pytest.
- Update schema, SQL contracts, documentation and diagrams together when changing tables.
