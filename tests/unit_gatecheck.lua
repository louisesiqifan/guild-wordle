-- TEMPORARY: verifies CI actually blocks a merge on a failing test.
-- Deleted immediately after; if you are reading this on a real branch,
-- something went wrong with the cleanup.
local T = require("runner")
require("harness")
T.test("deliberate failure to prove the CI gate blocks", function()
    T.assertEquals(1, 2, "this must fail")
end)
T.run()
