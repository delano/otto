Fixed
-----

- Error handlers now respect route's ``response=json`` parameter for content
  negotiation, ensuring API routes always return JSON error responses regardless
  of the Accept header.
