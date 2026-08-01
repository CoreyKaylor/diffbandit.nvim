local Budget = {}

Budget.limits = {
  requests = 100,
  window = 60,
}

function Budget.exceeded(count)
  return count > Budget.limits.requests
end

return Budget
