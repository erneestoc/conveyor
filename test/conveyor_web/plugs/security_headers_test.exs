defmodule ConveyorWeb.Plugs.SecurityHeadersTest do
  use ConveyorWeb.ConnCase, async: true

  test "browser responses carry a CSP whose nonce authorizes the theme script", %{conn: conn} do
    conn = get(conn, ~p"/auth/login")
    [csp] = get_resp_header(conn, "content-security-policy")
    [_, nonce] = Regex.run(~r/'nonce-([A-Za-z0-9_-]+)'/, csp)
    assert csp =~ "frame-ancestors 'none'"
    assert csp =~ "worker-src 'self'"
    assert html_response(conn, 200) =~ ~s(<script nonce="#{nonce}">)
    assert get_resp_header(conn, "x-frame-options") == ["DENY"]
    assert get_resp_header(conn, "permissions-policy") != []
  end

  test "artifact content types are sanitized" do
    import ConveyorWeb.DownloadController, only: [safe_content_type: 1]
    assert safe_content_type("application/gzip") == "application/gzip"
    assert safe_content_type("Text/Plain") == "text/plain"
    assert safe_content_type("text/html") == "application/octet-stream"
    assert safe_content_type("image/svg+xml") == "application/octet-stream"
    assert safe_content_type("application/javascript") == "application/octet-stream"
    assert safe_content_type("junk") == "application/octet-stream"
    assert safe_content_type("text/plain; charset=utf-8") == "application/octet-stream"
    assert safe_content_type(nil) == "application/octet-stream"
  end
end
