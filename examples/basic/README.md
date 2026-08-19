# Otto - Basic Example

This example demonstrates a basic Otto application with a single route that accepts both GET and POST requests.

## What You'll Learn

- How to define routes in plain-text format
- Creating a basic request handler class
- Working with Rack request and response objects
- Running an Otto application with Rackup
- Simple form handling and validation

## Run it

### Prerequisites

Run this example from an Otto source checkout with Ruby 3.2 through 4.0 and Bundler. `rackup` is a development dependency in the root `Gemfile`, so enable that optional group before installing the bundle.

```sh
git clone https://github.com/delano/otto.git
cd otto
bundle config set with development
bundle install
cd examples/basic
bundle exec rackup config.ru -p 10770
```

The server listens on `http://localhost:10770`.

> **Current limitation:** The checked-in app starts, but `GET /` currently returns `500` because `App#index` calls the undefined `otto_form_wrapper` helper. Until that source issue is fixed, the browser workflow below cannot be completed.

### Verify after fixing the source issue

In another terminal, confirm that the home page responds with HTML:

```sh
curl -i http://localhost:10770/
```

Expect `HTTP/1.1 200` and an HTML page containing `Otto Framework`. Open the same URL in a browser, enter a message, and submit the form. The form posts to `/` (not `/feedback`) and displays either the submitted message or the validation message for an empty submission.

## File Structure

* `README.md`: This file.
* `app.rb`: Contains the application logic with two methods:
  - `index`: Displays the main page with a feedback form
  - `receive_feedback`: Handles form submissions and renders the result
* `config.ru`: The Rack configuration file that loads Otto and the application.
- `routes`: Maps `GET /` to `App#index` and `POST /` to `App#receive_feedback`.

## Trying it out after resolving the limitation

1. **View the home page**: Open `http://localhost:10770` in your browser.
2. **Submit feedback**: Enter text in the feedback form and click **Send Feedback**.
3. **Check the result**: The response shows the submitted message and a link back to the home page.

## Next Steps

- Explore [Advanced Routes](../advanced_routes/) to learn about response type negotiation
- Check out [Authentication](../authentication_strategies/) for protecting routes
- See [Security Features](../security_features/) for CSRF, input validation, and more

## Further Reading

- [Project README](../../README.md) - Installation and framework overview
