using Genie.Router

function register_routes!()
    route("/health") do
        "OK"
    end

    return nothing
end
