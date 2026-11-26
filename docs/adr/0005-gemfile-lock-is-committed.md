# Gemfile.lock is committed, and CI installs from it

The lockfile used to be gitignored, which was harmless while the dependency list
was a handful of gems resolved on one machine. GitHub Actions changes that: an
uncommitted lockfile means every CI run resolves gems afresh, so the build can go
red without a single commit in the repository, and CI can test against versions
nobody develops on. The lockfile is therefore tracked, and the CI install runs in
deployment mode, which also refuses a `Gemfile` that was edited without
regenerating its lockfile.

Consequence: adding or bumping a gem now requires committing the regenerated
`Gemfile.lock` in the same commit. A `Gemfile` change that arrives without it
fails `bundle install` in CI rather than silently floating.
