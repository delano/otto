# Runtime and dependency security policy

This policy explains what Otto's Ruby and gem version declarations guarantee,
what they do not guarantee, and what applications using Otto must do to keep a
deployed bundle patched.

## Ruby compatibility and security maintenance

Otto separates **runtime compatibility** from **interpreter security
maintenance**. A blocking compatibility target must pass Otto's test suite;
provisional targets are exercised without blocking releases. Only the Ruby
project can provide security maintenance for the interpreter.

| Ruby version | Otto compatibility policy | CI status |
| --- | --- | --- |
| 3.2 | Retained as a compatibility target for now, despite upstream end of life | Blocking, with locked and freshly resolved dependencies |
| 3.3–3.4 | Supported compatibility targets | Blocking, with locked and freshly resolved dependencies |
| 3.5–4.0 | Accepted by the gem's Ruby version range, but compatibility remains provisional | Experimental and non-blocking, with locked and freshly resolved dependencies |

Ruby 3.2 reached upstream end of life on April 1, 2026. It receives no
interpreter security maintenance. Otto's continued compatibility testing cannot
correct vulnerabilities in Ruby 3.2 itself. Applications with a security
maintenance requirement should run Otto on a Ruby version that the Ruby project
currently maintains. Check the [Ruby branch maintenance
status](https://www.ruby-lang.org/en/downloads/branches/) when selecting a
runtime.

The `required_ruby_version` range in `otto.gemspec` controls whether RubyGems
may install Otto. It does not mean every version in that range has the same CI
or upstream security status. The table above is the support policy for the
current matrix.

## What dependency ranges mean

The runtime dependency ranges in `otto.gemspec` express the versions Otto
expects to be API-compatible with. Their lower bounds are compatibility
baselines, not a promise that every allowed version is free of known
vulnerabilities or still receives security fixes.

Otto may exclude a known-bad dependency release or raise a lower bound when a
vulnerability affects Otto users. Such a constraint is a targeted response, not
a substitute for auditing the complete resolved dependency graph. A future
advisory can make any previously acceptable version unsafe while it still
satisfies the gemspec.

Otto's committed `Gemfile.lock` makes maintainer development and CI resolution
reproducible. Bundler does not use that lockfile when Otto is installed as a
dependency of another application. Otto's locked and freshly resolved CI jobs
test compatibility; neither job selects or certifies a secure dependency set
for consumer applications.

## Consumer lockfile policy

The deployable application is responsible for the final dependency graph. An
application using Otto should:

1. Commit its `Gemfile.lock` and deploy that exact resolution.
2. Make [`bundler-audit`](https://github.com/rubysec/bundler-audit) available
   in application CI, then run it with an updated advisory database on every
   lockfile change, on a scheduled weekly job, and before each production
   deployment:

   ```sh
   bundle-audit check --update
   ```

3. Treat a relevant advisory as a release blocker. Update the affected gem and
   re-run the application's tests and audit. For a conservative targeted
   update, replace `GEM_NAME` with the affected gem:

   ```sh
   bundle update --conservative GEM_NAME
   bundle-audit check --update
   ```

4. Enable an automated dependency updater, or review `bundle outdated`
   manually at least weekly, so patched releases reach the application
   lockfile.
5. Audit the Ruby interpreter, operating system packages, and native libraries
   separately. `bundler-audit` checks Ruby gems; it does not make an
   end-of-life Ruby secure.

If the patched dependency version falls outside Otto's declared range,
applications should upgrade Otto when a compatible release is available and
report the blocked update to the maintainers. Do not assume that a successful
`bundle install` means the resolved bundle has no known vulnerabilities.
