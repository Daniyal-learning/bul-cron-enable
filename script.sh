#!/bin/bash

read -p "Enter Cloudways email: " email
read -sp "Enter Cloudways API key: " api_key
echo # Newline for readability

token_url="https://api.cloudways.com/api/v1/oauth/access_token"
server_url="https://api.cloudways.com/api/v1/server"
cron_setting_url="https://api.cloudways.com/api/v1/app/manage/cron_setting"
error_log_file="cron_setting_errors.log"  # File to log error responses

# Function to generate a new access token
generate_access_token() {
    echo "Generating access token..."
    response=$(curl -s -X POST "$token_url" \
        -H "Content-Type: application/json" \
        -d "{\"email\":\"$email\",\"api_key\":\"$api_key\"}")

    access_token=$(echo "$response" | jq -r '.access_token')

    if [[ $access_token == "null" || -z $access_token ]]; then
        echo "Failed to generate access token. Please check your email and API key."
        exit 1
    fi
    echo "Access token generated successfully."
}

# Initial token generation
generate_access_token

echo "Retrieving server and app IDs..."
server_response=$(curl -s -X GET "$server_url" \
    -H "Authorization: Bearer $access_token" \
    -H "Accept: application/json")

if [[ $(echo "$server_response" | jq -r '.status') != "true" ]]; then
    echo "Failed to retrieve server and app information."
    exit 1
fi

echo "$server_response" | jq -c '.servers[] | {ServerID: .id, AppIDs: [.apps[].id]}' > server_app_ids.json
echo "Server and app IDs saved to server_app_ids.json."

echo "Enabling cron optimizer for each app with a 40-second delay to avoid rate limiting and duplicate operations"
while IFS= read -r line; do
    server_id=$(echo "$line" | jq -r '.ServerID')
    app_ids=$(echo "$line" | jq -r '.AppIDs[]')

    for app_id in $app_ids; do
        cron_response=$(curl -s -X POST "$cron_setting_url" \
            --header 'Content-Type: application/x-www-form-urlencoded' \
            --header 'Accept: application/json' \
            --header "Authorization: Bearer $access_token" \
            -d "server_id=$server_id&app_id=$app_id&status=enable")

        status=$(echo "$cron_response" | jq -r '.status')

        # Check for "access_denied" error, indicating an expired token
        if [[ "$status" == "null" && $(echo "$cron_response" | jq -r '.error') == "access_denied" ]]; then
            echo "Access token expired. Generating a new token..."
            generate_access_token  # Refresh the token

            # Retry the API request with the new token
            cron_response=$(curl -s -X POST "$cron_setting_url" \
                --header 'Content-Type: application/x-www-form-urlencoded' \
                --header 'Accept: application/json' \
                --header "Authorization: Bearer $access_token" \
                -d "server_id=$server_id&app_id=$app_id&status=enable")

            status=$(echo "$cron_response" | jq -r '.status')
        fi

        # Log success or error
        if [[ "$status" == "true" ]]; then
            echo "Successfully enabled cron optimizer for AppID: $app_id on ServerID: $server_id"
        else
            echo "Failed to enable cron optimizer for AppID: $app_id on ServerID: $server_id (May not be a WordPress. Please check cron_setting_errors.log for more details)"
            echo "Error for AppID: $app_id on ServerID: $server_id - Response: $cron_response" >> "$error_log_file"
        fi

        sleep 40
    done
done < server_app_ids.json

echo "All operations completed."
