<?php

namespace DartApache\LivewireWebTransport;

use Illuminate\Support\Facades\Blade;
use Illuminate\Support\ServiceProvider;

class WebTransportServiceProvider extends ServiceProvider
{
    public function register(): void
    {
        $this->mergeConfigFrom(__DIR__ . '/../config/webtransport.php', 'webtransport');
    }

    public function boot(): void
    {
        $this->publishes([
            __DIR__ . '/../config/webtransport.php' => config_path('webtransport.php'),
        ], 'webtransport-config');

        $this->publishes([
            __DIR__ . '/../resources/js/livewire-webtransport.js' => public_path('vendor/livewire-webtransport/livewire-webtransport.js'),
        ], 'webtransport-assets');

        // @webtransport injects the CSRF meta tag, the shim config, and the
        // shim script. Place it in <head> BEFORE @livewireScripts.
        Blade::directive('webtransport', fn () => "<?php echo \\DartApache\\LivewireWebTransport\\WebTransportServiceProvider::render(); ?>");
    }

    public static function render(): string
    {
        $config = config('webtransport');
        if (! ($config['enabled'] ?? true)) {
            return '';
        }

        $csrf = csrf_token();
        $asset = asset('vendor/livewire-webtransport/livewire-webtransport.js');

        $js = [];
        if (! empty($config['url'])) {
            $js[] = 'window.LIVEWIRE_WT_URL=' . json_encode($config['url']) . ';';
        }
        if (array_key_exists('ticket_url', $config)) {
            $js[] = 'window.LIVEWIRE_WT_TICKET_URL=' . json_encode($config['ticket_url']) . ';';
        }
        if (! empty($config['endpoint'])) {
            $js[] = 'window.LIVEWIRE_WT_ENDPOINT=' . json_encode($config['endpoint']) . ';';
        }
        $configScript = $js ? '<script>' . implode('', $js) . '</script>' : '';

        return implode("\n", array_filter([
            '<meta name="csrf-token" content="' . e($csrf) . '">',
            $configScript,
            '<script src="' . e($asset) . '"></script>',
        ]));
    }
}
