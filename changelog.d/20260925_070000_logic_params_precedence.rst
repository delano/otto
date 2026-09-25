Security
--------

- A JSON body can no longer replace a path capture, query parameter or form
  field in Logic class parameters: it now merges below all of them. JSON
  bodies are no longer parsed on ``GET`` or ``HEAD`` requests.

Added
-----

- Logic classes can declare a ``route_params:`` keyword on ``initialize`` to
  receive the router's path captures separately from caller-supplied
  parameters.
