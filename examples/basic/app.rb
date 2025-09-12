# examples/basic/app.rb

require_relative '../../lib/otto/design_system'

# Basic example application demonstrating Otto framework features.
class App
  include Otto::DesignSystem

  attr_reader :req, :res

  def initialize(req, res)
    @req                        = req
    @res                        = res
    res.headers['content-type'] = 'text/html; charset=utf-8'
  end

  def index
    content = <<~HTML
      <div class="otto-card otto-text-center">
        <img src="/img/otto.jpg" alt="Otto Framework" class="otto-logo" />
        <h1>Otto Framework</h1>
        <p>Minimal Ruby web framework with style</p>
      </div>

      #{otto_card('Send Feedback') do
        otto_form_wrapper do
          otto_input('msg', placeholder: 'Your message...') +
          otto_button('Send Feedback')
        end
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
end
