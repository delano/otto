# Route syntax

This page is the compact contract for Otto's plain-text route definitions. It
covers the syntax needed to choose a route target and attach route options. For
application examples, start with the [routing guide](../guides/routing.md).

## Route line

A route line has this shape:

```text
VERB /path-pattern Target option=value option=value
```

For example:

```text
GET  /                         App#index
GET  /products/:id             App#show_product response=view
POST /api/products             ProductCreate response=json csrf=exempt
GET  /admin                    Admin::Dashboard auth=session role=admin
GET  /health                   &health_check
```

Whitespace separates the verb, path, target, and each option token. Option
values cannot contain unquoted whitespace. Values may contain `=` characters;
Otto splits each option at its first `=`.

## HTTP verbs and paths

The verb is normalized to uppercase. A path can contain named segments and a
splat:

```text
GET /products/:id          Products#show
GET /assets/*path          Assets#show
```

Named segments become route parameters. The splat is available under the
`"splat"` parameter name. Route matching is anchored to the complete path, and
Otto normalizes paths before matching, including trailing slashes and URL
encoding according to the router's path-normalization rules.

## Targets

The target determines how Otto invokes application code:

| Syntax | Kind | Invocation |
| --- | --- | --- |
| `App.index` | Class method | Calls `App.index(req, res)`. |
| `App#index` | Instance method | Builds `App.new(req, res)`, then calls `index`. |
| `Admin::Dashboard` | Logic class | Builds `Admin::Dashboard.new(strategy_result, params, locale)`, then runs its Logic lifecycle. |
| `&health_check` | Registered lambda | Looks up `"health_check"` in the boot-time `lambda_handlers` registry and calls it with `(req, res, extra_params)`. |

Class and instance targets must resolve to safe Ruby constants. Lambda targets
are registry keys, not Ruby constants: Otto does not evaluate route text or
resolve a lambda name dynamically.

### Logic classes

A bare class target is a Logic route. Logic classes receive a constrained
application context rather than the Rack request and environment:

```ruby
class ProductShow
  def initialize(strategy_result, params, locale)
    @context = strategy_result
    @params = params
    @locale = locale
  end

  def raise_concerns
    # Load resources and perform resource-level authorization here.
  end

  def process
    { id: @params[:id], locale: @locale }
  end
end
```

The route handler supplies the authenticated `StrategyResult` even for a public
route; public routes receive an anonymous result. Use a class or instance
handler when code needs direct access to cookies, headers, or the Rack request.

### Registered lambda handlers

Register lambdas before the first request:

```ruby
otto = Otto.new('routes', lambda_handlers: {
  health_check: lambda do |req, res, _extra_params|
    res['content-type'] = 'text/plain'
    res.body = 'ok'
  end,
})
```

The callable must accept three positional arguments. Registration validates the
name and callable arity at boot; a route referring to an unregistered handler
fails when it is invoked rather than evaluating arbitrary route text.

## Route options

Options are whitespace-delimited `key=value` tokens after the target.
Unknown well-formed options are retained for handlers and middleware that use
them. Malformed non-security options are ignored and logged.

### Response type

`response=` selects the response handler for non-default handler results:

| Option | Behavior |
| --- | --- |
| `response=default` | Default response behavior. This is the default. |
| `response=json` | JSON response handling. |
| `response=view` | View response handling. |
| `response=redirect` | Redirect response handling. |
| `response=auto` | Content-negotiated response handling. |

An unknown response type falls back to the default handler and logs in debug
mode.

### CSRF

When CSRF protection is enabled, use the explicit exemption only for routes
whose request contract does not use browser credentials and therefore has an
independent protection model:

```text
POST /webhooks/provider  Webhooks#receive csrf=exempt
```

`csrf=exempt` is the supported exemption token. A bare `csrf` or an empty CSRF
value is rejected as a malformed security option.

### Authentication and roles

Use `auth=` for one or more named authentication strategies and `role=` for
route-level role authorization:

```text
GET /account       Account#show auth=session
GET /admin         Admin::Dashboard auth=session role=admin
GET /editorial     Editorial#show auth=session role=admin,editor
GET /api/data      Api#show auth=session,api_key response=json
```

`auth=session,api_key` is OR logic: strategies run left to right, an
authenticated success stops the chain, and a later strategy can be tried after
a plain failure. `role=admin,editor` also uses OR logic: any listed role is
enough. See the [authentication guide](../guides/authentication.md).

Authentication and role options are security-gating options. They must use
lowercase `auth=`, `role=`, or `csrf=` with a non-empty value. Otto raises
`Otto::RouteDefinitionError` instead of silently treating a malformed token as
an unprotected route:

```text
# Rejected during route definition parsing:
GET /admin Admin#show auth
GET /admin Admin#show role=
POST /submit Form#save CSRF=exempt
```

## Configuration timing

Routes are loaded during `Otto.new`. Configuration remains available for
multi-step setup, but Otto freezes configuration on the first request in normal
operation. Register authentication strategies, lambda handlers, middleware,
helpers, and security settings before serving traffic.

## Related contracts

- [Routing guide](../guides/routing.md) — application-oriented examples.
- [Authentication guide](../guides/authentication.md) — strategy and
  authorization behavior.
- [Configuration and lifecycle code](../../lib/otto/core/configuration.rb) and
  [`RouteDefinition`](../../lib/otto/route_definition.rb) — implementation
  source for the exact contract.
