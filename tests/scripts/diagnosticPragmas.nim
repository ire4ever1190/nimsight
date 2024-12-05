#> :w
#> :wait textDocument/publishDiagnostics
{.warning: "Warning is shown".} #[
            ^ :Diag ]#
{.warning: "Make sure the test works".}
{.hint: "Hint is shown".} #[
         ^ :Diag ]#
{.error: "Error is shown.".} #[
          ^ :Diag ]#

