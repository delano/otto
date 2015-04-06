# Otto - 0.4

**Auto-define your rack-apps in plain-text.**

## Overview ##

Apps built with Otto have three, basic parts: a rackup file, a ruby file, and a routes file. If you've built a [Rack app](http://rack.rubyforge.org/) before, then you've seen a rackup file before. The ruby file is your actual app and the routes file is what Otto uses to map URI paths to a Ruby class and method.

A barebones app directory looks something like this:

    $ cd myapp
    $ ls
    config.ru app.rb routes

See the examples/ directory for a working app.


### Routes ###

The routes file is just a plain-text file which defines the end points of your application. Each route has three parts:

 * HTTP verb (GET, POST, PUT, DELETE or HEAD)
 * URI path
 * Ruby class and method to call

Here is an example:

    GET   /                         App#index
    POST  /                         App#receive_feedback
    GET   /redirect                 App#redirect
    GET   /robots.txt               App#robots_text
    GET   /product/:prodid          App#display_product

    # You can also define these handlers when no
    # route can be found or there's a server error. (optional)
    GET   /404                      App#not_found
    GET   /500                      App#server_error

### App ###

There is nothing special about the Ruby class. The only requirement is that the first two arguments to initialize be a Rack::Request object and a Rack::Response object. Otherwise, you can do anything you want. You're free to use any templating engine, any database mapper, etc. There is no magic.

    class App
      attr_reader :req, :res

      # Otto creates an instance of this class for every request
      # and passess the Rack::Request and Rack::Response objects.
      def initialize req, res
        @req, @res = req, res
      end

      def index
        res.header['Content-Type'] = "text/html; charset=utf-8"
        lines = [
          '<img src="/img/otto.jpg" /><br/><br/>',
          'Send feedback:<br/>',
          '<form method="post"><input name="msg" /><input type="submit" /></form>',
          '<a href="/product/100">A product example</a>'
        ]
        res.body = lines.join($/)
      end

      def receive_feedback
        res.body = req.params.inspect
      end

      def redirect
        res.redirect '/robots.txt'
      end

      def robots_text
        res.header['Content-Type'] = "text/plain"
        rules = 'User-agent: *', 'Disallow: /private'
        res.body = rules.join($/)
      end

      def display_product
        res.header['Content-Type'] = "application/json; charset=utf-8"
        prodid = req.params[:prodid]
        res.body = '{"product":%s,"msg":"Hint: try another value"}' % [prodid]
      end

      def not_found
        res.status = 404
        res.body = "Item not found!"
      end

      def server_error
        res.status = 500
        res.body = "There was a server error!"
      end
    end

### Rackup ###

There is also nothing special about the rackup file. It just builds a Rack app using your routes file.

    require 'otto'
    require 'app'

    app = Otto.new("./routes")

    map('/') {
      run app
    }

See the examples/ directory for a working app.


## Installation

Get it in one of the following ways:

    $ gem install otto
    $ sudo gem install otto
    $ git clone git://github.com/delano/otto.git

You can also download via [tarball](http://github.com/delano/otto/tarball/latest) or [zip](http://github.com/delano/otto/zipball/latest).


## More Information

* [Codes](http://github.com/delano/otto)
* [RDocs](http://solutious.com/otto)


## In the wild ##

Services that use Otto:

* [One-Time Secret](https://onetimesecret.com/) -- A safe way to share sensitive data.
* [BlameStella](https://www.blamestella.com/) -- Web monitoring for devs and designers.


## Credits

* [Delano Mandelbaum](http://solutious.com)


## Related Projects

* [Sinatra](http://www.sinatrarb.com/)

## License

See LICENSE.txt
