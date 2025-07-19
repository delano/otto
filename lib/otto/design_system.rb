# lib/otto/design_system.rb

class Otto
  module DesignSystem
    # Shared design system for Otto framework examples
    # Provides consistent styling, components, and utilities

    def otto_page(content, title = "Otto Framework", additional_head = "")
      <<~HTML
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>#{escape_html(title)}</title>
            #{otto_styles}
            #{additional_head}
        </head>
        <body>
            <div class="otto-container">
                #{content}
            </div>
        </body>
        </html>
      HTML
    end

    def otto_form_wrapper(csrf_tag = "", &block)
      content = block_given? ? yield : ""
      <<~HTML
        <form method="post" class="otto-form">
          #{csrf_tag}
          #{content}
        </form>
      HTML
    end

    def otto_input(name, type: "text", placeholder: "", value: "", required: false)
      req_attr = required ? "required" : ""
      val_attr = value.empty? ? "" : %{value="#{escape_html(value)}"}

      <<~HTML
        <input
          type="#{type}"
          name="#{name}"
          placeholder="#{escape_html(placeholder)}"
          #{val_attr}
          #{req_attr}
          class="otto-input"
        />
      HTML
    end

    def otto_textarea(name, placeholder: "", value: "", rows: 4, required: false)
      req_attr = required ? "required" : ""

      <<~HTML
        <textarea
          name="#{name}"
          rows="#{rows}"
          placeholder="#{escape_html(placeholder)}"
          #{req_attr}
          class="otto-input"
        >#{escape_html(value)}</textarea>
      HTML
    end

    def otto_button(text, type: "submit", variant: "primary", size: "default")
      size_class = size == "small" ? "otto-btn-sm" : ""

      <<~HTML
        <button type="#{type}" class="otto-btn otto-btn-#{variant} #{size_class}">
          #{escape_html(text)}
        </button>
      HTML
    end

    def otto_alert(type, title, message, dismissible: false)
      dismiss_btn = dismissible ? '<button class="otto-alert-dismiss" onclick="this.parentElement.remove()">×</button>' : ""

      <<~HTML
        <div class="otto-alert otto-alert-#{type}">
          #{dismiss_btn}
          <h3 class="otto-alert-title">#{escape_html(title)}</h3>
          <p class="otto-alert-message">#{escape_html(message)}</p>
        </div>
      HTML
    end

    def otto_card(title = nil, &block)
      content = block_given? ? yield : ""
      title_html = title ? "<h2 class=\"otto-card-title\">#{escape_html(title)}</h2>" : ""

      <<~HTML
        <div class="otto-card">
          #{title_html}
          #{content}
        </div>
      HTML
    end

    def otto_link(text, href, external: false)
      target_attr = external ? 'target="_blank" rel="noopener noreferrer"' : ""

      <<~HTML
        <a href="#{escape_html(href)}" class="otto-link" #{target_attr}>
          #{escape_html(text)}
        </a>
      HTML
    end

    def otto_code_block(code, language = "")
      <<~HTML
        <div class="otto-code-block">
          <pre><code class="language-#{language}">#{escape_html(code)}</code></pre>
        </div>
      HTML
    end

    private

    def escape_html(text)
      return '' if text.nil?
      text.to_s
          .gsub('&', '&amp;')
          .gsub('<', '&lt;')
          .gsub('>', '&gt;')
          .gsub('"', '&quot;')
          .gsub("'", '&#x27;')
    end

    def otto_styles
      <<~CSS
        <style>
            :root {
                /* Otto Character-Inspired Colors */
                --otto-primary: #E879F9;        /* Otto's pink shirt */
                --otto-primary-dark: #C026D3;   /* Deeper pink */
                --otto-primary-light: #F3E8FF;  /* Light pink tint */
                --otto-secondary: #A855F7;      /* Otto's purple shorts */
                --otto-accent: #FB923C;         /* Otto's orange hat */

                /* Semantic Colors */
                --otto-success: #059669;
                --otto-success-light: #D1FAE5;
                --otto-warning: #D97706;
                --otto-warning-light: #FEF3C7;
                --otto-error: #DC2626;
                --otto-error-light: #FEE2E2;
                --otto-info: #0284C7;
                --otto-info-light: #E0F2FE;

                /* Neutral Palette */
                --otto-gray-50: #F9FAFB;
                --otto-gray-100: #F3F4F6;
                --otto-gray-200: #E5E7EB;
                --otto-gray-300: #D1D5DB;
                --otto-gray-400: #9CA3AF;
                --otto-gray-500: #6B7280;
                --otto-gray-600: #4B5563;
                --otto-gray-700: #374151;
                --otto-gray-800: #1F2937;
                --otto-gray-900: #111827;

                /* Typography */
                --otto-font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Roboto', sans-serif;
                --otto-font-mono: 'SF Mono', Consolas, 'Liberation Mono', Menlo, monospace;

                /* Spacing Scale */
                --otto-space-xs: 0.25rem;
                --otto-space-sm: 0.5rem;
                --otto-space-md: 1rem;
                --otto-space-lg: 1.5rem;
                --otto-space-xl: 2rem;
                --otto-space-2xl: 3rem;

                /* Border Radius */
                --otto-radius-sm: 4px;
                --otto-radius-md: 8px;
                --otto-radius-lg: 12px;
                --otto-radius-xl: 16px;

                /* Shadows */
                --otto-shadow: 0 1px 3px 0 rgba(0, 0, 0, 0.1), 0 1px 2px 0 rgba(0, 0, 0, 0.06);
                --otto-shadow-md: 0 4px 6px -1px rgba(0, 0, 0, 0.1), 0 2px 4px -1px rgba(0, 0, 0, 0.06);
                --otto-shadow-lg: 0 10px 15px -3px rgba(0, 0, 0, 0.1), 0 4px 6px -2px rgba(0, 0, 0, 0.05);
                --otto-shadow-xl: 0 20px 25px -5px rgba(0, 0, 0, 0.1), 0 10px 10px -5px rgba(0, 0, 0, 0.04);

                /* Transitions */
                --otto-transition: all 0.2s ease;
                --otto-transition-fast: all 0.1s ease;
                --otto-transition-slow: all 0.3s ease;
            }

            * {
                box-sizing: border-box;
            }

            body {
                font-family: var(--otto-font-family);
                line-height: 1.6;
                color: var(--otto-gray-900);
                background: linear-gradient(135deg, var(--otto-gray-50) 0%, #ffffff 100%);
                margin: 0;
                min-height: 100vh;
                font-size: 16px;
            }

            /* Logo Component */
            .otto-logo {
                max-width: 120px;
                height: auto;
                margin-bottom: var(--otto-space-md);
                border-radius: var(--otto-radius-md);
                display: block;
                margin-left: auto;
                margin-right: auto;
            }

            /* Layout Components */
            .otto-container {
                max-width: 800px;
                margin: 0 auto;
                padding: var(--otto-space-xl);
            }

            .otto-card {
                background: white;
                padding: var(--otto-space-xl);
                margin-bottom: var(--otto-space-xl);
                border-radius: var(--otto-radius-lg);
                box-shadow: var(--otto-shadow);
                border: 1px solid var(--otto-gray-100);
            }

            .otto-card-title {
                margin: 0 0 var(--otto-space-lg) 0;
                color: var(--otto-gray-900);
                font-size: 1.5rem;
                font-weight: 600;
            }

            /* Form Components */
            .otto-form {
                display: flex;
                flex-direction: column;
                gap: var(--otto-space-md);
            }

            .otto-input {
                padding: 0.75rem;
                border: 2px solid var(--otto-gray-200);
                border-radius: var(--otto-radius-md);
                font-size: 1rem;
                transition: var(--otto-transition);
                background: white;
                font-family: var(--otto-font-family);
            }

            .otto-input:focus {
                outline: none;
                border-color: var(--otto-primary);
                box-shadow: 0 0 0 3px rgba(45, 125, 210, 0.1);
            }

            .otto-input::placeholder {
                color: var(--otto-gray-400);
            }

            /* Button Components */
            .otto-btn {
                padding: 0.75rem var(--otto-space-lg);
                border: none;
                border-radius: var(--otto-radius-md);
                font-size: 1rem;
                font-weight: 600;
                cursor: pointer;
                transition: var(--otto-transition);
                text-decoration: none;
                display: inline-flex;
                align-items: center;
                justify-content: center;
                min-height: 44px;
                font-family: var(--otto-font-family);
            }

            .otto-btn-primary {
                background: linear-gradient(135deg, var(--otto-primary) 0%, var(--otto-primary-dark) 100%);
                color: white;
                box-shadow: var(--otto-shadow);
            }

            .otto-btn-primary:hover {
                transform: translateY(-1px);
                box-shadow: var(--otto-shadow-lg);
            }

            .otto-btn-secondary {
                background: var(--otto-gray-100);
                color: var(--otto-gray-700);
                border: 1px solid var(--otto-gray-200);
            }

            .otto-btn-secondary:hover {
                background: var(--otto-gray-200);
                transform: translateY(-1px);
            }

            .otto-btn-sm {
                padding: 0.5rem var(--otto-space-md);
                font-size: 0.875rem;
                min-height: 36px;
            }

            .otto-btn:active {
                transform: translateY(0);
            }

            .otto-btn:disabled {
                opacity: 0.6;
                cursor: not-allowed;
                transform: none !important;
            }

            /* Link Components */
            .otto-link {
                color: var(--otto-primary);
                text-decoration: none;
                font-weight: 500;
                transition: var(--otto-transition);
            }

            .otto-link:hover {
                color: var(--otto-primary-dark);
                text-decoration: underline;
            }

            /* Alert Components */
            .otto-alert {
                padding: var(--otto-space-lg);
                border-radius: var(--otto-radius-md);
                margin-bottom: var(--otto-space-lg);
                border-left: 4px solid;
                position: relative;
            }

            .otto-alert-title {
                margin: 0 0 var(--otto-space-sm) 0;
                font-size: 1.125rem;
                font-weight: 600;
            }

            .otto-alert-message {
                margin: 0;
                line-height: 1.5;
            }

            .otto-alert-success {
                background-color: var(--otto-success-light);
                border-left-color: var(--otto-success);
                color: #166534;
            }

            .otto-alert-error {
                background-color: var(--otto-error-light);
                border-left-color: var(--otto-error);
                color: #991B1B;
            }

            .otto-alert-warning {
                background-color: var(--otto-warning-light);
                border-left-color: var(--otto-warning);
                color: #92400E;
            }

            .otto-alert-info {
                background-color: var(--otto-info-light);
                border-left-color: var(--otto-info);
                color: #1E40AF;
            }

            .otto-alert-dismiss {
                position: absolute;
                top: var(--otto-space-sm);
                right: var(--otto-space-sm);
                background: none;
                border: none;
                font-size: 1.5rem;
                cursor: pointer;
                color: inherit;
                opacity: 0.7;
                width: 24px;
                height: 24px;
                display: flex;
                align-items: center;
                justify-content: center;
            }

            .otto-alert-dismiss:hover {
                opacity: 1;
            }

            /* Code Components */
            .otto-code-block {
                background: var(--otto-gray-50);
                border: 1px solid var(--otto-gray-200);
                border-radius: var(--otto-radius-md);
                overflow: auto;
            }

            .otto-code-block pre {
                margin: 0;
                padding: var(--otto-space-md);
                font-family: var(--otto-font-mono);
                font-size: 0.875rem;
                line-height: 1.4;
            }

            .otto-code-block code {
                color: var(--otto-gray-800);
            }

            /* Utility Classes */
            .otto-text-center { text-align: center; }
            .otto-text-left { text-align: left; }
            .otto-text-right { text-align: right; }

            .otto-mb-0 { margin-bottom: 0; }
            .otto-mb-sm { margin-bottom: var(--otto-space-sm); }
            .otto-mb-md { margin-bottom: var(--otto-space-md); }
            .otto-mb-lg { margin-bottom: var(--otto-space-lg); }

            .otto-mt-0 { margin-top: 0; }
            .otto-mt-sm { margin-top: var(--otto-space-sm); }
            .otto-mt-md { margin-top: var(--otto-space-md); }
            .otto-mt-lg { margin-top: var(--otto-space-lg); }

            /* Responsive Design */
            @media (max-width: 640px) {
                .otto-container {
                    padding: var(--otto-space-md);
                }

                .otto-card {
                    padding: var(--otto-space-lg);
                }

                .otto-btn {
                    width: 100%;
                }
            }

            /* Print Styles */
            @media print {
                .otto-btn,
                .otto-alert-dismiss {
                    display: none;
                }

                body {
                    background: white;
                }

                .otto-card {
                    box-shadow: none;
                    border: 1px solid var(--otto-gray-300);
                }
            }
        </style>
      CSS
    end
  end
end
