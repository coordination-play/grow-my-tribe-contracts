#!/usr/bin/env bash

# Ensure the script stops on first error
set -e

# Global variables
file_path="$HOME/.starknet_accounts/starknet_open_zeppelin_accounts.json"
CONTRACT_NAME="Registry"
PROFILE_NAME="account1"
# MULTICALL_FILE="multicall.toml"
FAILED_TESTS=false

# Addresses and Private keys as environment variables
ACCOUNT1_ADDRESS=${ACCOUNT1_ADDRESS:-"0x8b4848564df4f427120198fb1844f49e7f7ec0c12513070bbb28d10f1034e8"}
ACCOUNT2_ADDRESS=${ACCOUNT2_ADDRESS:-"0x722f9bff02831f3b4713f70785f93d768a335f0759c4527225d40904c543e23"}
ACCOUNT1_PRIVATE_KEY=${ACCOUNT1_PRIVATE_KEY:-"0x81141e87ec0a03d1c40909f29d2126e2"}
ACCOUNT2_PRIVATE_KEY=${ACCOUNT2_PRIVATE_KEY:-"0xe3db9da1a4ccaba361a94403d8f5a76c"}

# Utility function to log messages
function log_message() {
    echo -e "\n$1"
}

# Step 1: Clean previous environment
if [ -e "$file_path" ]; then
    log_message "Removing existing accounts file..."
    rm -rf "$file_path"
fi

# Step 2: Define accounts for the smart contract
accounts_json=$(cat <<EOF
[
    {
        "name": "account1",
        "address": "$ACCOUNT1_ADDRESS",
        "private_key": "$ACCOUNT1_PRIVATE_KEY"
    },
    {
        "name": "account2",
        "address": "$ACCOUNT2_ADDRESS",
        "private_key": "$ACCOUNT2_PRIVATE_KEY"
    }
]
EOF
)

# Step 3: Run contract tests
echo -e "\nTesting the contract..."
testing_result=$(snforge test 2>&1)
if echo "$testing_result" | grep -q "Failure"; then
    echo -e "Tests failed!\n"
    snforge
    echo -e "\nEnsure that your tests are passing before proceeding.\n"
    FAILED_TESTS=true
fi

if [ "$FAILED_TESTS" != "true" ]; then
    echo "Tests passed successfully."

    # Step 4: Create new account(s)
    echo -e "\nCreating account(s)..."
    for row in $(echo "${accounts_json}" | jq -c '.[]'); do
        name=$(echo "${row}" | jq -r '.name')
        address=$(echo "${row}" | jq -r '.address')
        private_key=$(echo "${row}" | jq -r '.private_key')

        account_creation_result=$(sncast --url http://localhost:5050/rpc account add --name "$name" --address "$address" --private-key "$private_key" --add-profile 2>&1)
        if echo "$account_creation_result" | grep -q "error:"; then
            echo "Account $name already exists."
        else
            echo "Account $name created successfully."
        fi
    done

    # Step 5: Build, declare, and deploy the contract
    echo -e "\nBuilding the contract..."
    scarb build

    echo -e "\nDeclaring the contract..."
    declaration_output=$(sncast --profile "$PROFILE_NAME" --wait declare --contract-name "$CONTRACT_NAME" 2>&1)

    if echo "$declaration_output" | grep -q "error: Class with hash"; then
        echo "Class hash already declared."
        CLASS_HASH=$(echo "$declaration_output" | sed -n 's/.*Class with hash \([^ ]*\).*/\1/p') ## Uncomment this for devnet python
        # CLASS_HASH=$(echo "$declaration_output" | sed -n 's/.*StarkFelt("\(.*\)").*/\1/p') ## Uncomment this for devnet rust
    else
        echo "New class hash declaration."
        CLASS_HASH=$(echo "$declaration_output" | grep -o 'class_hash: 0x[^ ]*' | sed 's/class_hash: //')
    fi

    echo "Class Hash: $CLASS_HASH"

    echo -e "\nDeploying the contract..."
    deployment_result=$(sncast --profile "$PROFILE_NAME" deploy --class-hash "$CLASS_HASH")
    CONTRACT_ADDRESS=$(echo "$deployment_result" | grep -o "contract_address: 0x[^ ]*" | awk '{print $2}')
    echo "Contract address: $CONTRACT_ADDRESS"

    # Step 6: Create and execute multicalls
    echo -e "\nSetting up multicall..."
    cat >"$MULTICALL_FILE" <<-EOM
[[call]]
call_type = 'invoke'
contract_address = '$CONTRACT_ADDRESS'
function = 'increase_balance'
inputs = ['0x1']

[[call]]
call_type = 'invoke'
contract_address = '$CONTRACT_ADDRESS'
function = 'increase_balance'
inputs = ['0x2']
EOM

    echo "Executing multicall..."
    sncast --profile "$PROFILE_NAME" multicall run --path "$MULTICALL_FILE"

    # Step 7: Query the contract state
    echo -e "\nChecking balance..."
    sncast --profile "$PROFILE_NAME" call --contract-address "$CONTRACT_ADDRESS" --function get_balance

    # Step 8: Clean up temporary files
    echo -e "\nCleaning up..."
    [ -e "$MULTICALL_FILE" ] && rm "$MULTICALL_FILE"

    echo -e "\nScript completed successfully.\n"
fi
