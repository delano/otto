# examples/basic/app.rb (Streamlined with Design System)

require_relative '../../lib/otto/design_system'

class App
  include Otto::DesignSystem

  attr_reader :req, :res

  def initialize(req, res)
    @req                        = req
    @res                        = res
    res.headers['content-type'] = 'text/html; charset=utf-8'
  end

  def index
    # This demonstrates nested heredocs in Ruby
    # The outer heredoc uses <<~HTML delimiter
    content = <<~HTML
      <div class="otto-card otto-text-center">
        <img src="/img/otto.jpg" alt="Otto Framework" class="otto-logo" />
        <h1>Otto Framework</h1>
        <p>Minimal Ruby web framework with style</p>
      </div>

      #{otto_card('Dynamic Pages') do
        # This is a nested heredoc within the outer HTML heredoc
        # It uses a different delimiter (EXAMPLES) to avoid conflicts
        # The #{} interpolation allows the inner heredoc to be embedded
        <<~EXAMPLES
          #{otto_link('Product #100', '/product/100')} - View product page<br>
          #{otto_link('Product #42', '/product/42')} - Different product<br>
          #{otto_link('API Data', '/product/100.json')} - JSON endpoint
        EXAMPLES
      end}
    HTML

    res.send_secure_cookie :sess, 1_234_567, 3600
    res.body = otto_page(content)
  end

  def receive_feedback
    message = req.params['msg']&.strip

    content = if message.nil? || message.empty?
      otto_alert('error', 'Empty Message', 'Please enter a message before submitting.')
    else
      otto_alert('success', 'Feedback Received', 'Thanks for your message!') +
        otto_card('Your Message') { otto_code_block(message, 'text') }
    end

    content += "<p>#{otto_link('← Back', '/')}</p>"
    res.body = otto_page(content, 'Feedback')
  end

  def redirect
    res.redirect '/robots.txt'
  end

  def robots_text
    res.headers['content-type'] = 'text/plain'
    res.body                    = ['User-agent: *', 'Disallow: /private'].join($/)
  end

  def display_product
    prodid = req.params[:prodid]

    # Check if JSON is requested via .json extension or Accept header
    wants_json = req.path_info.end_with?('.json') ||
                 req.env['HTTP_ACCEPT']&.include?('application/json')

    if wants_json
      res.headers['content-type'] = 'application/json; charset=utf-8'
      res.body                    = format('{"product":%s,"msg":"Hint: try another value"}', prodid)
    else
      # Return HTML product page
      product_data = {
        'Product ID' => prodid,
        'Name' => "Sample Product ##{prodid}",
        'Price' => "$#{rand(10..999)}.99",
        'Description' => 'This is a demonstration product showing dynamic routing with parameter :prodid',
        'Stock' => rand(0..50) > 5 ? 'In Stock' : 'Out of Stock',
      }

      product_html = product_data.map do |key, value|
        "<p><strong>#{key}:</strong> #{escape_html(value.to_s)}</p>"
      end.join

      content = <<~HTML
        #{otto_card('Product Details') { product_html }}

        <p>
          #{otto_link('← Back to Home', '/')} |
          #{otto_link('View as JSON', "/product/#{prodid}.json")}
        </p>
      HTML

      res.body = otto_page(content, "Product ##{prodid}")
    end
  end

  def not_found
    res.status = 404
    content    = otto_alert('error', 'Not Found', 'The requested page could not be found.')
    content   += "<p>#{otto_link('← Home', '/')}</p>"
    res.body   = otto_page(content, '404')
  end

  def server_error
    res.status = 500
    content    = otto_alert('error', 'Server Error', 'An internal server error occurred.')
    content   += "<p>#{otto_link('← Home', '/')}</p>"
    res.body   = otto_page(content, '500')
  end
end
