defmodule Conveyor.Ingest.ScrubTest do
  use ExUnit.Case, async: true

  alias BuildEventStream, as: BES
  alias Conveyor.Bep.Fixture
  alias Conveyor.Ingest.Scrub

  @fixture Path.join(File.cwd!(), "test/fixtures/bep/clean_build_and_test.bep")

  test "redacts header flags, url credentials, generic secrets and bearer tokens" do
    assert Scrub.text("--bes_header=x-api-key=conveyor_abc_secret --foo=bar") ==
             "--bes_header=x-api-key=<redacted> --foo=bar"

    assert Scrub.text("--remote_header=Authorization=Bearer%20xyz") ==
             "--remote_header=Authorization=<redacted>"

    assert Scrub.text("--remote_cache=https://user:pa55@cache.example.com/x") ==
             "--remote_cache=https://<redacted>@cache.example.com/x"

    assert Scrub.text("token=abc password=def api_key=ghi") ==
             "token=<redacted> password=<redacted> api_key=<redacted>"

    assert Scrub.text("Authorization: Bearer abc.def-ghi") == "Authorization: Bearer <redacted>"
    assert Scrub.text("nothing here") == "nothing here"
    assert Scrub.text(nil) == nil
  end

  test "redacts credential-like environment variables Bazel copies into the command line" do
    assert Scrub.text("--client_env=AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG") ==
             "--client_env=AWS_SECRET_ACCESS_KEY=<redacted>"

    assert Scrub.text("AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE") == "AWS_ACCESS_KEY_ID=<redacted>"

    assert Scrub.text("--action_env=GITHUB_TOKEN=ghp_abc --test_env=npm_auth_token=x") ==
             "--action_env=GITHUB_TOKEN=<redacted> --test_env=npm_auth_token=<redacted>"

    assert Scrub.text("--repo_env=DB_PASSWORD=hunter2 --client_env=PATH=/usr/bin:/bin") ==
             "--repo_env=DB_PASSWORD=<redacted> --client_env=PATH=/usr/bin:/bin"

    assert Scrub.text("--build_metadata=USER=alice --client_env=HOME=/Users/alice") ==
             "--build_metadata=USER=alice --client_env=HOME=/Users/alice"
  end

  test "scrubs every command-line carrying payload and reports whether it changed" do
    secret = "--bes_header=x-api-key=conveyor_k_s3cret"

    base = %BES.BuildEvent{
      id: %BES.BuildEventId{id: {:started, %BES.BuildEventId.BuildStartedId{}}}
    }

    events = [
      %{base | payload: {:started, %BES.BuildStarted{options_description: secret}}},
      %{
        base
        | payload:
            {:unstructured_command_line, %BES.UnstructuredCommandLine{args: ["bazel", secret]}}
      },
      %{
        base
        | payload:
            {:options_parsed,
             %BES.OptionsParsed{
               cmd_line: [secret],
               explicit_cmd_line: [secret],
               startup_options: [],
               explicit_startup_options: []
             }}
      },
      %{base | payload: {:progress, %BES.Progress{stdout: "", stderr: "INFO: #{secret}\n"}}},
      %{
        base
        | payload:
            {:action,
             %BES.ActionExecuted{
               command_line: ["sh", "-c", "curl -H 'Authorization: Bearer tok'"]
             }}
      },
      %{
        base
        | payload:
            {:structured_command_line,
             %CommandLine.CommandLine{
               command_line_label: "canonical",
               sections: [
                 %CommandLine.CommandLineSection{
                   section_label: "chunks",
                   section_type: {:chunk_list, %CommandLine.ChunkList{chunk: [secret]}}
                 },
                 %CommandLine.CommandLineSection{
                   section_label: "options",
                   section_type:
                     {:option_list,
                      %CommandLine.OptionList{
                        option: [
                          %CommandLine.Option{
                            combined_form: secret,
                            option_name: "bes_header",
                            option_value: "x-api-key=conveyor_k_s3cret"
                          }
                        ]
                      }}
                 },
                 %CommandLine.CommandLineSection{section_label: "empty"}
               ]
             }}
      }
    ]

    for event <- events do
      {scrubbed, changed?} = Scrub.event(event)
      assert changed?, "expected #{inspect(elem(event.payload, 0))} to change"
      refute scrubbed |> BES.BuildEvent.encode() |> String.contains?("s3cret")
      refute scrubbed |> BES.BuildEvent.encode() |> String.contains?("Bearer tok")
      assert {^scrubbed, false} = Scrub.event(scrubbed)
    end
  end

  test "recorded fixtures are already scrubbed, so scrubbing them again changes nothing" do
    for event <- Fixture.read!(@fixture) do
      assert {^event, false} = Scrub.event(event)
    end
  end

  test "the prefilter only skips strings no pattern can match" do
    refute Scrub.candidate?("//app:pass_test")
    refute Scrub.candidate?("Build completed successfully, 12 total actions\n")
    refute Scrub.candidate?("--jobs=8")
    refute Scrub.candidate?("--client_env=HOME=/home/me")
    assert Scrub.candidate?("--client_env=GITHUB_TOKEN=abc")
    assert Scrub.candidate?("--bes_header=x-api-key=abc")
    assert Scrub.candidate?("https://user:pw@host/repo")
    assert Scrub.candidate?("Authorization: bEaReR abc.def")

    assert Scrub.text("--jobs=8") == "--jobs=8"
    assert Scrub.text("Authorization: bEaReR abc.def") == "Authorization: bEaReR <redacted>"
    assert Scrub.text("ssh://user:pw@host/repo") == "ssh://<redacted>@host/repo"

    assert Scrub.text("--client_env=NPM_AUTH=xyz --jobs=8") ==
             "--client_env=NPM_AUTH=<redacted> --jobs=8"
  end
end
