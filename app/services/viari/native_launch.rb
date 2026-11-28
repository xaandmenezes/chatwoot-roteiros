class Viari::NativeLaunch
  def initialize(origin, result)
    @origin = origin
    @result = result
  end

  def data
    url = URI.parse(@result.fetch('url'))
    raise Viari::Client::Unavailable unless url.is_a?(URI::HTTP) && url.scheme == @origin.scheme &&
                                           url.host == @origin.host && url.port == @origin.port && url.userinfo.nil? &&
                                           url.path == '/atendimento/nativo' && url.fragment.nil?

    @result.slice('url', 'mode', 'expiresAt', 'channel').merge('origin' => "#{@origin.scheme}://#{@origin.host}#{port_suffix}")
  rescue URI::InvalidURIError, KeyError, TypeError
    raise Viari::Client::Unavailable
  end

  private

  def port_suffix
    @origin.port == @origin.default_port ? '' : ":#{@origin.port}"
  end
end
