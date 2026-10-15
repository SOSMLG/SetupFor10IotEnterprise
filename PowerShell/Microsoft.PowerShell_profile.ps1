# Win10/Win11 IoT LTSC base profile (PS 5.1, stock console)
try {
    [Console]::InputEncoding  = [System.Text.Encoding]::UTF8
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    $OutputEncoding = [System.Text.UTF8Encoding]::new($false)
    chcp 65001 > $null
} catch {}

# arrows walk history, and the console bell stays quiet. stock psreadline is enough.
try {
    Set-PSReadLineOption -BellStyle None
    Set-PSReadLineKeyHandler -Key UpArrow   -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
} catch {}

# shell pack from the linux box. every piece is guarded: a missing tool is not an error.
if (Get-Command starship -EA SilentlyContinue) { Invoke-Expression (&starship init powershell) }
if (Get-Command zoxide -EA SilentlyContinue) { Invoke-Expression (& { (zoxide init powershell | Out-String) }) }
if (Get-Command eza -EA SilentlyContinue) {
    # eza listing aliases. ls and cat stay stock on purpose, scripts expect them.
    function ll { eza -la --group --header --git --icons --group-directories-first @args }
    function la { eza -la --group --header --git --icons --group-directories-first @args }
    function lt { eza --tree --level=2 --icons @args }
    function lh { eza -la --group --sort=modified --reverse @args }
}
# fzf keybinds need the psfzf module. without it, native ctrl+r still searches history.
try {
    if (Get-Module -ListAvailable -Name PSFzf) {
        Import-Module PSFzf -EA Stop
        Set-PsFzfOption -PSReadlineChordProvider 'Ctrl+t' -PSReadlineChordReverseHistory 'Ctrl+r'
    }
} catch {}

Clear-Host
# fastfetch on a fresh interactive shell, not in scripted runs (installs, tests).
if ((Get-Command fastfetch -EA SilentlyContinue) -and $Host.Name -eq 'ConsoleHost' -and -not [Console]::IsOutputRedirected) { fastfetch }
