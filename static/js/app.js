// Mobile navigation toggle
document.addEventListener('DOMContentLoaded', function() {
    const hamburger = document.querySelector('.hamburger');
    const navMenu = document.querySelector('.nav-menu');

    if (hamburger && navMenu) {
        hamburger.addEventListener('click', function() {
            hamburger.classList.toggle('active');
            navMenu.classList.toggle('active');
        });

        // Close menu when clicking on a link
        document.querySelectorAll('.nav-link').forEach(n => n.addEventListener('click', () => {
            hamburger.classList.remove('active');
            navMenu.classList.remove('active');
        }));
    }

    // Package search functionality
    const searchInput = document.getElementById('package-search');
    const packageCards = document.querySelectorAll('.package-card');
    
    if (searchInput && packageCards.length > 0) {
        searchInput.addEventListener('input', function() {
            const searchTerm = this.value.toLowerCase();
            
            packageCards.forEach(card => {
                const name = card.getAttribute('data-name')?.toLowerCase() || '';
                const author = card.getAttribute('data-author')?.toLowerCase() || '';
                const description = card.querySelector('.package-description')?.textContent.toLowerCase() || '';
                
                if (name.includes(searchTerm) || author.includes(searchTerm) || description.includes(searchTerm)) {
                    card.style.display = '';
                } else {
                    card.style.display = 'none';
                }
            });
        });
    }

    // Filter functionality
    const versionFilter = document.getElementById('version-filter');
    const statusFilter = document.getElementById('status-filter');
    const sortFilter = document.getElementById('sort-filter');

    function applyFilters() {
        const versionValue = versionFilter?.value || '';
        const statusValue = statusFilter?.value || '';
        
        packageCards.forEach(card => {
            let showCard = true;
            
            // Version filter
            if (versionValue) {
                const compatItems = card.querySelectorAll('.compat-item');
                let hasVersion = false;
                compatItems.forEach(item => {
                    const version = item.querySelector('.zig-version')?.textContent || '';
                    if (version === versionValue) {
                        hasVersion = true;
                    }
                });
                if (!hasVersion) showCard = false;
            }
            
            // Status filter
            if (statusValue) {
                const statusItems = card.querySelectorAll('.build-status');
                let hasStatus = false;
                statusItems.forEach(item => {
                    if (item.classList.contains(`status-${statusValue}`)) {
                        hasStatus = true;
                    }
                });
                if (!hasStatus) showCard = false;
            }
            
            card.style.display = showCard ? '' : 'none';
        });
    }

    if (versionFilter) versionFilter.addEventListener('change', applyFilters);
    if (statusFilter) statusFilter.addEventListener('change', applyFilters);

    // Sort functionality
    if (sortFilter) {
        sortFilter.addEventListener('change', function() {
            const sortValue = this.value;
            const packagesGrid = document.getElementById('packages-grid');
            
            if (packagesGrid) {
                const cards = Array.from(packagesGrid.children);
                
                cards.sort((a, b) => {
                    switch (sortValue) {
                        case 'name':
                            const nameA = a.getAttribute('data-name') || '';
                            const nameB = b.getAttribute('data-name') || '';
                            return nameA.localeCompare(nameB);
                            
                        case 'updated':
                            // Would need data-updated attribute
                            return 0;
                            
                        case 'popularity':
                            // Would need data-popularity attribute
                            return 0;
                            
                        case 'compatibility':
                            const successA = a.querySelectorAll('.status-success').length;
                            const successB = b.querySelectorAll('.status-success').length;
                            return successB - successA;
                            
                        default:
                            return 0;
                    }
                });
                
                // Reorder the cards
                cards.forEach(card => packagesGrid.appendChild(card));
            }
        });
    }

    // Smooth scrolling for anchor links
    document.querySelectorAll('a[href^="#"]').forEach(anchor => {
        anchor.addEventListener('click', function (e) {
            e.preventDefault();
            const target = document.querySelector(this.getAttribute('href'));
            if (target) {
                target.scrollIntoView({
                    behavior: 'smooth'
                });
            }
        });
    });

    // Auto-refresh status (could be connected to websockets in the future)
    function updateStatus() {
        const statusElement = document.querySelector('.status');
        if (statusElement) {
            // Placeholder for real status checking
            console.log('Status check - all systems operational');
        }
    }

    // Check status every 30 seconds
    setInterval(updateStatus, 30000);

    // Handle package submission form
    const submitForm = document.getElementById('submit-form');
    if (submitForm) {
        submitForm.addEventListener('submit', async function(e) {
            e.preventDefault(); // Prevent default form submission
            
            const formData = new FormData(this);
            const packageData = {
                name: formData.get('name'),
                url: formData.get('url'),
                description: formData.get('description'),
                author: formData.get('author'),
                license: formData.get('license') || null
            };
            
            // Validate required fields
            if (!packageData.name || !packageData.url || !packageData.description || !packageData.author) {
                alert('Please fill in all required fields');
                return;
            }
            
            // Get submit button and store original text
            const submitButton = this.querySelector('button[type="submit"]');
            const originalText = submitButton.innerHTML;
            
            try {
                // Disable submit button and show loading state
                submitButton.disabled = true;
                submitButton.innerHTML = '<i class="fas fa-spinner fa-spin mr-2"></i>Submitting...';
                
                const result = await window.PackageChecker.submitPackage(packageData);
                
                // Show success message and redirect
                alert('Package submitted successfully! Build process has been started.');
                window.location.href = '/packages';
                
            } catch (error) {
                console.error('Error submitting package:', error);
                alert('Error submitting package. Please try again.');
                
                // Re-enable submit button
                submitButton.disabled = false;
                submitButton.innerHTML = originalText;
            }
        });
    }
});

// API helper functions
window.PackageChecker = {
    // Fetch package data
    async fetchPackages(page = 1, limit = 20, search = '', filters = {}) {
        try {
            const params = new URLSearchParams({
                page: page.toString(),
                limit: limit.toString(),
                search,
                ...filters
            });
            
            const response = await fetch(`/api/packages?${params}`);
            return await response.json();
        } catch (error) {
            console.error('Error fetching packages:', error);
            return { packages: [], total: 0 };
        }
    },

    // Submit a new package
    async submitPackage(packageData) {
        try {
            const response = await fetch('/api/packages', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify(packageData)
            });
            
            return await response.json();
        } catch (error) {
            console.error('Error submitting package:', error);
            throw error;
        }
    },

    // Get build results for a package
    async getBuildResults(packageName) {
        try {
            const response = await fetch(`/api/packages/${packageName}/builds`);
            return await response.json();
        } catch (error) {
            console.error('Error fetching build results:', error);
            return [];
        }
    },

    // Trigger a new build
    async triggerBuild(packageName, zigVersion) {
        try {
            const response = await fetch(`/api/packages/${packageName}/builds`, {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ zig_version: zigVersion })
            });
            
            return await response.json();
        } catch (error) {
            console.error('Error triggering build:', error);
            throw error;
        }
    }
};

// Mobile menu toggle
function toggleMobileMenu() {
    const mobileMenu = document.getElementById('mobile-menu');
    if (mobileMenu.style.display === 'none' || mobileMenu.style.display === '') {
        mobileMenu.style.display = 'block';
    } else {
        mobileMenu.style.display = 'none';
    }
} 