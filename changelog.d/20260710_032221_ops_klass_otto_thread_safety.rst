Security
--------

- ``Otto::Route::ClassMethods#otto=`` no longer stores the current
  ``Otto`` instance in a plain class-level accessor (#188). Every request
  mutated ``klass.otto`` in place, so two ``Otto`` instances sharing a
  controller/logic class — or concurrent threads/fibers serving requests
  under different ``Otto`` instances — could race and clobber it, letting
  a handler observe the wrong ``security_config``/``auth_config`` for the
  duration of a request. The accessor is now backed by a fiber-local
  ``Thread.current`` slot keyed by the target class, scoping each
  assignment to the thread/fiber actually serving that request. The public
  ``klass.otto`` / ``klass.otto=`` API is unchanged.
