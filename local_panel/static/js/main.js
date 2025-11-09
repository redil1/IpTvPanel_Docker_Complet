// IPTV Panel JavaScript

// Auto-dismiss alerts after 5 seconds
document.addEventListener('DOMContentLoaded', function() {
    const alerts = document.querySelectorAll('.alert');
    alerts.forEach(function(alert) {
        setTimeout(function() {
            const bsAlert = new bootstrap.Alert(alert);
            bsAlert.close();
        }, 5000);
    });
});

// Copy to clipboard function
function copyToClipboard(text) {
    navigator.clipboard.writeText(text).then(function() {
        alert('Copied to clipboard!');
    }).catch(function(err) {
        console.error('Failed to copy:', err);
    });
}

// Confirm delete actions
document.querySelectorAll('form[onsubmit*="confirm"]').forEach(function(form) {
    form.addEventListener('submit', function(e) {
        if (!confirm('Are you sure?')) {
            e.preventDefault();
        }
    });
});

// Auto-refresh dashboard stats every 30 seconds
if (window.location.pathname === '/') {
    setInterval(function() {
        fetch('/api/stats')
            .then(response => response.json())
            .then(data => {
                // Update dashboard stats if elements exist
                const elements = {
                    total_users: document.querySelector('.card.bg-primary h2'),
                    active_users: document.querySelector('.card.bg-success h2'),
                    active_connections: document.querySelector('.card.bg-warning h2'),
                    total_channels: document.querySelector('.card.bg-info h2')
                };
                
                if (elements.total_users) elements.total_users.textContent = data.total_users;
                if (elements.active_users) elements.active_users.textContent = data.active_users;
                if (elements.active_connections) elements.active_connections.textContent = data.active_connections;
                if (elements.total_channels) elements.total_channels.textContent = data.total_channels;
            })
            .catch(err => console.error('Stats refresh failed:', err));
    }, 30000);
}
