local Budget = {}

Budget.limits = {
  requests = 500,
  window = 120,
}

function Budget.exceeded(count)
  return count > Budget.limits.requests
end

return Budget
