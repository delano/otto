Security
--------

- Logic class parameters now merge in a fixed order: path captures win over
  the query string, the query string wins over a form body, and a form body
  wins over a JSON body. Previously a JSON body key replaced the value the
  router matched from the path. JSON bodies are no longer parsed on ``GET`` or
  ``HEAD`` requests.
