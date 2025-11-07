# Otto - Basic Example

This example demonstrates a basic Otto application with a single route that accepts both GET and POST requests.

## What You'll Learn

- How to define routes in plain-text format
- Creating a basic request handler class
- Working with Rack request and response objects
- Running an Otto application with different servers
- Simple form handling and redirects

## How to Run

### Using rackup (recommended)

```sh
cd examples/basic
rackup config.ru -p 10770
```

### Using thin

```sh
cd examples/basic
thin -e dev -R config.ru -p 10770 start
```

### Using puma

```sh
cd examples/basic
puma config.ru -p 10770
```

Open your browser and navigate to `http://localhost:10770`.

## Expected Output

```
Puma starting in single threaded mode...
* Version 3.12.0 (ruby 3.2.0-p0), codename: Llama Litter Box
* Min threads: 0, max threads: 32
* Environment: development
* Listening on tcp://127.0.0.1:10770

[GET request to /]
GET /  200 OK

[Submitting feedback form]
POST /feedback  302 Found
Location: http://localhost:10770/
```

Then visit `http://localhost:10770` and submit feedback to see it in action.

## File Structure

* `README.md`: This file.
* `app.rb`: Contains the application logic with two methods:
  - `index`: Displays the main page with a feedback form
  - `receive_feedback`: Handles form submissions and redirects back home
* `config.ru`: The Rack configuration file that loads Otto and the application.
* `routes`: Defines the URL routes mapping to methods in the `App` class.

## Trying It Out

1. **View the home page**: Open `http://localhost:10770` in your browser
2. **Submit feedback**: Enter text in the feedback form and click Submit
3. **Check the redirect**: You should be redirected back to the home page

## Next Steps

- Explore [Advanced Routes](../advanced_routes/) to learn about response type negotiation
- Check out [Authentication](../authentication_strategies/) for protecting routes
- See [Security Features](../security_features/) for CSRF, input validation, and more

## Further Reading

- [CLAUDE.md](../../CLAUDE.md) - Developer guidance and patterns
