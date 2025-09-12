module V2
  module Admin
    class Panel
      def self.show
        [200, { 'content-type' => 'text/html' }, ['<h1>V2 Admin Panel</h1><p>Class method implementation</p>']]
      end
    end
  end
end
