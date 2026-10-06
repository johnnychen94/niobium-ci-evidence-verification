# Glossary

Terms match MVP v0.1 (see [docs/roadmap-v0.1.md](docs/roadmap-v0.1.md)). Code identifiers use the English names in parentheses.

## Current MVP

- **Artifact (artifact)**: an immutable release object identified by SHA-256; one of PortableExecutable, PortableBundle, InstallableComponent.
- **Component (component)**: a deployable unit delivered by a component developer, with metadata, files and named entrypoints; it carries no install scripts and owns no absolute machine paths.
- **Product (product)**: a set of components, branding and OS integration declarations that a product packager composes in a declarative manifest.
- **Release (release)**: one release decision pointing at a set of artifacts, ordered by `release_sequence`.
- **release_sequence**: a monotonically increasing release number, separate from `app_version`, so an application version can be deliberately downgraded without tripping TUF rollback protection.
- **Channel (channel)**: a mutable signed pointer such as `stable`/`beta`/`nightly` that names a release.
- **Scope (scope)**: `user` or `machine`; decides the install root and whether elevation is needed.
- **DesiredState**: the target state resolved from the manifest plus user choices.
- **InstallationPlan (plan)**: the typed operation sequence the Planner compiles from DesiredState and InstalledState.
- **Transaction (transaction)**: one execution of a plan, with a jsonl journal that can be replayed, rolled back or ignored.
- **Staging**: the not-yet-active new version directory `versions/<seq>/`.
- **Commit**: the atomic step that makes the new version the only Active one through a pointer swap.
- **Active**: the version the `current` pointer names; the invariant is that it is only ever OLD or NEW.
- **Recovery**: `RecoverIncompleteTransaction`, run first at startup.
- **Capability (capability)**: a closed OS integration capability known to the framework: ManagedFiles, Directory, Shortcut, FileAssociation, Service, ApplicationRegistration.
- **Privilege Broker / Helper**: the elevation channel that exists only for the duration of a transaction and accepts only closed ops; `setup --priv-helper-v1`.
- **Maintainer (maintainer)**: the framework runtime kept after installation under the reserved component name `__installer_runtime`, used for update/repair/uninstall.
- **App Bootstrap (bootstrap)**: after commit, the application is invoked with `--installer-bootstrap-v1` and performs business migration over stdin/stdout JSON.
- **Profile**: one of three deployment capability boundaries, InstalledApplication, PortableRun and EmbeddedUpdate; security capabilities are not inherited between them.
- **PortableExecutable**: a native executable that can be verified, cached and run without installation.
- **RepositorySource**: one of three sources, Http / Directory / Embedded, each presenting the same TUF metadata + artifacts view to the resolver.
- **VirtualPlatform**: a test platform implementation that can inject deterministic faults.
- **UiTree / DisplayList / SemanticTree**: the three deterministic intermediate products of the UI pipeline, describing structure, drawing and accessibility semantics respectively.

## Deferred terms

- **EmbeddedUpdate / distribution.node**: the Electron embedded-update profile and Node-API addon (not implemented in v0.1).
- **Commit Activator (dist-activate)**: the short-lived handoff helper for embedded updates.
- **External Compatibility Provider**: the abstraction over external compatibility-testing platforms.
