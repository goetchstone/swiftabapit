# 2026-11-19 — The device list dropped Mosyle's 400, and the reason in its body

- **Symptom:** the operator's first live check, Settings → Test on a real Mosyle Business org. The login answered 200; the
  next request, the device list for Macs (page 1, asking for the adapter's 33 columns), answered HTTP 400. Test said only
  "400" (`MosyleAPIError.unexpected`), so nobody saw why Mosyle refused, and the column fallback never ran.
- **Cause:** `MosyleClient.envelope(_:)` threw `.unexpected(status:)` for any 4xx it didn't name and dropped the body, so:
  - Mosyle's own `status` and `info` never reached the operator;
  - a column refusal (`UNKNOWN_COLUMNS`) sent with HTTP 400 never reached `devicesPage`'s fallback, which read only a 2xx
    envelope.
  The likeliest refusal is a column: a review on 2026-11-18 found that six of the 33 columns are not listed by Mosyle's
  in-console doc. Those six are `enrollment_type`, `currentconsolemanageduser`, `imei`, `meid`, `date_enroll` and
  `date_checkin`. The 400's body was not seen, so that is not confirmed.
- **Why not caught:** the stub answered a column refusal with HTTP 200 and named the columns inside `info`. No source shows
  that shape. Mosyle's doc shows the refusal as `unknown_columns`, `status` `UNKNOWN_COLUMNS` and `info` "Unknown columns",
  and gives no HTTP code. Because the stub agreed with the client's guess, every fallback test passed on an answer the live
  tenant doesn't send. No test read a 4xx's Mosyle body: `a405IsInvalidMethod` drove the stub's 405 body, but checked
  only the status.
- **Fix:** https://github.com/goetchstone/swiftabapit/pull/22 (branch `mosyle-columns-live`): `fix(mosyle): read Mosyle's
  400, learn which device columns it offers, and say so`, then its review's fixes.
  - **Refusals:** a refusal is read the same inside a 2xx or with HTTP 400, in the envelope or bare. Its names are
    `unknown_columns` together with the words of `info`.
  - **The column steps (the operator's decision, 2026-11-19):** a refusal that names columns drops exactly those. A
    refusal that names none asks for the 27 documented columns. Once Mosyle takes those, each of the six is tried alone
    beside them, and the ones Mosyle takes are kept in memory for the client's life. The tries start only when the
    answer to the 27 reads as rows or as the list's end. A try is kept only when its answer reads as rows, as many as that
    page had, or as the end where the page was the end; any other answer leaves the column untried and the page stands.
    Every column is asked for only when the documented columns themselves are refused without a name, or when Mosyle
    names every column asked for. A refusal can bring at most seven more requests per client (1 + 6). With none left, a
    refusal is the error: columns it names are kept as refused, unless it names every column asked for, when the next
    read asks for the same ones and says so.
  - **Other errors:** any other 4xx or 5xx of a read carries Mosyle's `status` and `info`, cleaned and cut
    (`MosyleAPIError.answered`); a top-level `status` only when shaped as a code. The log gets only Mosyle's status
    code, never its `info`.
  - **What is said:** Settings → Test, the devices' note and a failed device read say which columns Mosyle refused, which
    it took, and which were left out untried.
- **Prevention:** the stub now answers a column refusal with HTTP 400 and the doc's body. It can refuse any of the
  undocumented columns (`MosyleStub.undocumentedColumns`), and a test holds each path:
  - `aRefusedColumnIsAnsweredAsMosylesDocShows`
  - `aRefusalReachesTheFallbackAt200Or400`
  - `anUnnamedRefusalTriesEachUndocumentedColumnAlone`
  - `theTriesAreBoundedPerClient`
  - `aRefusedReadSaysMosylesOwnWords`
  - `aTestSaysWhichColumnsMosyleRefusedAndTook`

  This is still a greener stub, not a proof. The HTTP code and the shape of a refusal are assumed, and so is which of the
  six Mosyle takes. The next live Test settles them (docs/domains/mosyle.md, "Assumed, check live").
