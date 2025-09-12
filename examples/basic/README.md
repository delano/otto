# Otto - Basic Example

This example demonstrates a basic Otto application with a single route that accepts both GET and POST requests.

## How to Run

1.  Make sure you have `bundler` and `thin` installed:
```sh
  gem install bundler thin
```

2.  Install the dependencies from the root of the project:
```sh
  bundle install
```

3.  Start the server from this directory (`examples/basic`):
```sh
  thin -e dev -R config.ru -p 10770 start
```

4.  Open your browser and navigate to `http://localhost:10770`.

## File Structure

* `README.md`: This file.
* `app.rb`: Contains the application logic. It has two methods: `index` to display the main page and `receive_feedback` to handle form submissions.
* `config.ru`: The Rack configuration file that loads the Otto framework and the application.
* `routes`: Defines the URL routes and maps them to methods in the `App` class.
