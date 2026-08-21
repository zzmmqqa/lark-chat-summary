$ErrorActionPreference = 'Stop'

$appId = [Environment]::GetEnvironmentVariable('APP_ID', 'User')
$appSecret = [Environment]::GetEnvironmentVariable('APP_SECRET', 'User')

if ([string]::IsNullOrWhiteSpace($appId) -or [string]::IsNullOrWhiteSpace($appSecret)) {
    throw 'APP_ID or APP_SECRET is missing from the Windows user environment.'
}

$env:APP_ID = $appId
$env:APP_SECRET = $appSecret

& npx.cmd -y '@larksuiteoapi/lark-mcp@0.5.1' mcp `
    --token-mode tenant_access_token `
    --tools 'im.v1.chat.list,im.v1.message.list,im.v1.chatMembers.get,im.v1.chatMembers.isInChat' `
    --language zh

exit $LASTEXITCODE
