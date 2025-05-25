// Zig Package Checker - Frontend JavaScript

document.addEventListener('DOMContentLoaded', function() {
    console.log('Zig Package Checker loaded');
    
    // Initialize features
    initializePackageSearch();
    initializeSubmissionForm();
    initializePackageFilters();
    initializeAdminFeatures();
});

// Package filtering and search functionality
let currentFilters = {
    search: '',
    zig_version: '',
    status: '',
    license: '',
    author: '',
    sort: 'updated',
    page: 1,
    limit: 20
};

let isLoading = false;

function initializePackageFilters() {
    // Only initialize on packages page
    if (!document.getElementById('packages-grid')) return;
    
    console.log('Initializing package filters');
    
    // Get filter elements
    const searchInput = document.getElementById('package-search');
    const versionFilter = document.getElementById('version-filter');
    const statusFilter = document.getElementById('status-filter');
    const licenseFilter = document.getElementById('license-filter');
    const authorFilter = document.getElementById('author-filter');
    const sortFilter = document.getElementById('sort-filter');
    
    // Set up event listeners with debouncing for search
    let searchTimeout;
    if (searchInput) {
        searchInput.addEventListener('input', function() {
            clearTimeout(searchTimeout);
            searchTimeout = setTimeout(() => {
                currentFilters.search = this.value;
                currentFilters.page = 1; // Reset to first page
                loadPackages();
            }, 300); // 300ms debounce
        });
    }
    
    // Set up immediate event listeners for filters
    if (versionFilter) {
        versionFilter.addEventListener('change', function() {
            currentFilters.zig_version = this.value;
            currentFilters.page = 1;
            loadPackages();
        });
    }
    
    if (statusFilter) {
        statusFilter.addEventListener('change', function() {
            currentFilters.status = this.value;
            currentFilters.page = 1;
            loadPackages();
        });
    }
    
    if (licenseFilter) {
        licenseFilter.addEventListener('change', function() {
            currentFilters.license = this.value;
            currentFilters.page = 1;
            loadPackages();
        });
    }
    
    if (authorFilter) {
        authorFilter.addEventListener('change', function() {
            currentFilters.author = this.value;
            currentFilters.page = 1;
            loadPackages();
        });
    }
    
    if (sortFilter) {
        sortFilter.addEventListener('change', function() {
            currentFilters.sort = this.value;
            currentFilters.page = 1;
            loadPackages();
        });
    }
    
    // Load initial data and populate author and license filters
    loadAuthors();
    loadLicenses();
}

async function loadPackages() {
    if (isLoading) return;
    
    isLoading = true;
    showLoading(true);
    
    try {
        // Build query parameters
        const params = new URLSearchParams();
        Object.keys(currentFilters).forEach(key => {
            if (currentFilters[key]) {
                params.append(key, currentFilters[key]);
            }
        });
        
        console.log('Loading packages with filters:', currentFilters);
        
        const response = await fetch(`/api/packages?${params.toString()}`);
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const data = await response.json();
        console.log('Loaded packages:', data);
        
        renderPackages(data.packages);
        renderPagination(data.total, data.page, data.limit);
        
    } catch (error) {
        console.error('Error loading packages:', error);
        showError('Failed to load packages. Please try again.');
    } finally {
        isLoading = false;
        showLoading(false);
    }
}

async function loadAuthors() {
    try {
        // Load all packages to get unique authors
        const response = await fetch('/api/packages?limit=1000');
        if (!response.ok) return;
        
        const data = await response.json();
        const authors = [...new Set(data.packages.map(pkg => pkg.author).filter(Boolean))].sort();
        
        const authorFilter = document.getElementById('author-filter');
        if (authorFilter && authors.length > 0) {
            // Clear existing options except the first one
            while (authorFilter.children.length > 1) {
                authorFilter.removeChild(authorFilter.lastChild);
            }
            
            // Add author options
            authors.forEach(author => {
                const option = document.createElement('option');
                option.value = author;
                option.textContent = author;
                authorFilter.appendChild(option);
            });
        }
    } catch (error) {
        console.error('Error loading authors:', error);
    }
}

async function loadLicenses() {
    try {
        // Load all packages to get unique licenses
        const response = await fetch('/api/packages?limit=1000');
        if (!response.ok) return;
        
        const data = await response.json();
        const licenses = [...new Set(data.packages.map(pkg => pkg.license).filter(Boolean))].sort();
        
        const licenseFilter = document.getElementById('license-filter');
        if (licenseFilter && licenses.length > 0) {
            // Clear existing options except the first one (All Licenses)
            while (licenseFilter.children.length > 1) {
                licenseFilter.removeChild(licenseFilter.lastChild);
            }
            
            // Add license options with mapping for common short names
            const licenseMapping = {
                'MIT License': 'MIT',
                'Apache License 2.0': 'Apache-2.0',
                'GNU General Public License v3.0': 'GPL-3.0',
                'BSD 3-Clause "New" or "Revised" License': 'BSD-3-Clause',
                'ISC License': 'ISC',
                'The Unlicense': 'Unlicense',
                'Mozilla Public License 2.0': 'MPL-2.0'
            };
            
            licenses.forEach(license => {
                const option = document.createElement('option');
                // Use short name as value if available, otherwise use full name
                option.value = licenseMapping[license] || license;
                option.textContent = license;
                licenseFilter.appendChild(option);
            });
        }
    } catch (error) {
        console.error('Error loading licenses:', error);
    }
}

function renderCompatibilityMatrix(buildResults) {
    // Default Zig versions to show
    const zigVersions = ['0.12.0', '0.13.0', '0.14.0', 'master'];
    
    return zigVersions.map(version => {
        // Find build result for this version
        const buildResult = buildResults.find(result => result.zig_version === version);
        const status = buildResult ? buildResult.build_status : 'pending';
        
        // Determine icon and color based on status
        let iconClass, bgClass;
        switch (status) {
            case 'success':
                iconClass = 'fas fa-check text-green-600';
                bgClass = 'bg-green-100';
                break;
            case 'failed':
                iconClass = 'fas fa-times text-red-600';
                bgClass = 'bg-red-100';
                break;
            default:
                iconClass = 'fas fa-clock text-yellow-600';
                bgClass = 'bg-yellow-100';
        }
        
        return `
            <div class="flex items-center justify-between p-2 bg-gray-50 rounded">
                <span class="text-sm font-medium text-gray-700">${version}</span>
                <span class="flex items-center justify-center w-6 h-6 rounded-full ${bgClass}">
                    <i class="${iconClass} text-xs"></i>
                </span>
            </div>
        `;
    }).join('');
}

function renderPackages(packages) {
    const grid = document.getElementById('packages-grid');
    if (!grid) return;
    
    if (packages.length === 0) {
        grid.innerHTML = `
            <div class="col-span-full text-center py-16">
                <i class="fas fa-box-open text-6xl text-gray-400 mb-6"></i>
                <h3 class="text-2xl font-bold text-gray-800 mb-2">No packages found</h3>
                <p class="text-gray-600 mb-6">No packages match your current filters. Try adjusting your search criteria.</p>
                <a href="/submit" class="inline-block bg-zig-orange text-white px-6 py-3 rounded-lg font-semibold hover:bg-orange-600 transition-colors">Submit a Package</a>
            </div>
        `;
        return;
    }
    
    grid.innerHTML = packages.map(pkg => `
        <div class="bg-white rounded-lg shadow-md border border-gray-200 overflow-hidden hover:shadow-lg transition-shadow duration-200" data-name="${pkg.name}" data-author="${pkg.author || ''}">
            <!-- Package Header -->
            <div class="p-6 border-b border-gray-100">
                <h3 class="text-xl font-bold text-gray-900 mb-2">
                    <a href="/packages/${pkg.name}" class="hover:text-zig-orange transition-colors">${escapeHtml(pkg.name)}</a>
                </h3>
                <div class="flex items-center gap-4 text-sm text-gray-600">
                    <span class="flex items-center gap-1">
                        <i class="fas fa-user"></i>
                        ${escapeHtml(pkg.author || 'Unknown')}
                    </span>
                    <span class="flex items-center gap-1">
                        <i class="fas fa-clock"></i>
                        ${formatDate(pkg.created_at)}
                    </span>
                </div>
            </div>
            
            <!-- Package Description -->
            <div class="p-6 border-b border-gray-100">
                <p class="text-gray-700 leading-relaxed">${escapeHtml(pkg.description || 'No description available')}</p>
            </div>

            <!-- Compatibility Matrix -->
            <div class="p-6 border-b border-gray-100">
                <h4 class="text-lg font-semibold text-gray-900 mb-3">Compatibility Matrix</h4>
                <div class="grid grid-cols-2 gap-2">
                    ${renderCompatibilityMatrix(pkg.build_results || [])}
                </div>
            </div>

            <!-- Package Actions -->
            <div class="p-6 flex gap-3">
                <a href="${pkg.url}" class="flex-1 text-center px-4 py-2 border border-gray-300 text-gray-700 rounded-lg hover:bg-gray-50 transition-colors text-sm font-medium" target="_blank">
                    <i class="fas fa-external-link-alt mr-2"></i>
                    Repository
                </a>
                <a href="/packages/${pkg.name}" class="flex-1 text-center px-4 py-2 bg-zig-orange text-white rounded-lg hover:bg-orange-600 transition-colors text-sm font-medium">
                    View Details
                </a>
            </div>

            ${pkg.license ? `
            <div class="px-6 pb-6">
                <div class="flex items-center gap-2 text-sm text-gray-600 bg-gray-50 p-2 rounded">
                    <i class="fas fa-balance-scale"></i>
                    <span>${escapeHtml(pkg.license)}</span>
                </div>
            </div>
            ` : ''}
        </div>
    `).join('');
    
    // Add admin buttons if in admin mode
    if (isAdminMode) {
        addAdminButtonsToPackages();
    }
}

function renderPagination(total, currentPage, limit) {
    const pagination = document.getElementById('pagination');
    if (!pagination) return;
    
    const totalPages = Math.ceil(total / limit);
    if (totalPages <= 1) {
        pagination.innerHTML = '';
        return;
    }
    
    let paginationHTML = '<div class="flex items-center gap-2">';
    
    // Previous button
    if (currentPage > 1) {
        paginationHTML += `
            <button onclick="changePage(${currentPage - 1})" class="px-3 py-2 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors">
                <i class="fas fa-chevron-left"></i>
            </button>
        `;
    }
    
    // Page numbers
    const startPage = Math.max(1, currentPage - 2);
    const endPage = Math.min(totalPages, currentPage + 2);
    
    if (startPage > 1) {
        paginationHTML += `<button onclick="changePage(1)" class="px-3 py-2 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors">1</button>`;
        if (startPage > 2) {
            paginationHTML += '<span class="px-2">...</span>';
        }
    }
    
    for (let i = startPage; i <= endPage; i++) {
        const isActive = i === currentPage;
        paginationHTML += `
            <button onclick="changePage(${i})" class="px-3 py-2 border rounded-lg transition-colors ${
                isActive 
                    ? 'bg-zig-orange text-white border-zig-orange' 
                    : 'border-gray-300 hover:bg-gray-50'
            }">${i}</button>
        `;
    }
    
    if (endPage < totalPages) {
        if (endPage < totalPages - 1) {
            paginationHTML += '<span class="px-2">...</span>';
        }
        paginationHTML += `<button onclick="changePage(${totalPages})" class="px-3 py-2 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors">${totalPages}</button>`;
    }
    
    // Next button
    if (currentPage < totalPages) {
        paginationHTML += `
            <button onclick="changePage(${currentPage + 1})" class="px-3 py-2 border border-gray-300 rounded-lg hover:bg-gray-50 transition-colors">
                <i class="fas fa-chevron-right"></i>
            </button>
        `;
    }
    
    paginationHTML += '</div>';
    pagination.innerHTML = paginationHTML;
}

function changePage(page) {
    currentFilters.page = page;
    loadPackages();
    
    // Scroll to top of packages grid
    const grid = document.getElementById('packages-grid');
    if (grid) {
        grid.scrollIntoView({ behavior: 'smooth' });
    }
}

function showLoading(show) {
    const loadingIndicator = document.getElementById('loading-indicator');
    const packagesGrid = document.getElementById('packages-grid');
    
    if (loadingIndicator) {
        loadingIndicator.classList.toggle('hidden', !show);
    }
    
    if (packagesGrid) {
        packagesGrid.style.opacity = show ? '0.5' : '1';
    }
}

function showError(message) {
    const grid = document.getElementById('packages-grid');
    if (grid) {
        grid.innerHTML = `
            <div class="col-span-full text-center py-16">
                <i class="fas fa-exclamation-triangle text-6xl text-red-400 mb-6"></i>
                <h3 class="text-2xl font-bold text-gray-800 mb-2">Error</h3>
                <p class="text-gray-600 mb-6">${escapeHtml(message)}</p>
                <button onclick="loadPackages()" class="inline-block bg-zig-orange text-white px-6 py-3 rounded-lg font-semibold hover:bg-orange-600 transition-colors">Try Again</button>
            </div>
        `;
    }
}

function escapeHtml(text) {
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

function formatDate(dateString) {
    try {
        const date = new Date(dateString);
        return date.toLocaleDateString();
    } catch {
        return dateString;
    }
}

function initializePackageSearch() {
    // This function is now handled by initializePackageFilters
    // Keep for backward compatibility
}

function initializeSubmissionForm() {
    const submitForm = document.getElementById('package-submit-form');
    if (submitForm) {
        submitForm.addEventListener('submit', function(e) {
            // TODO: Add form validation and AJAX submission
            console.log('Form submitted');
        });
    }
}

// Admin functionality
let adminToken = null;
let isAdminMode = false;

function initializeAdminFeatures() {
    // Check if admin token is stored in localStorage
    adminToken = localStorage.getItem('admin_token');
    if (adminToken) {
        verifyAdminToken();
    }
    
    // Add admin login button to navigation if not already present
    addAdminLoginButton();
    
    // Initialize admin panel if on packages page
    if (document.getElementById('packages-grid')) {
        initializeAdminPanel();
    }
}

function addAdminLoginButton() {
    // Check if admin button already exists
    if (document.getElementById('admin-login-btn')) return;
    
    const adminButton = document.createElement('button');
    adminButton.id = 'admin-login-btn';
    adminButton.className = 'fixed top-20 right-4 z-50 px-3 py-2 bg-gray-800 text-white rounded-lg text-sm hover:bg-gray-700 transition-colors shadow-lg';
    adminButton.innerHTML = isAdminMode ? '<i class="fas fa-user-shield mr-1"></i> Admin' : '<i class="fas fa-key mr-1"></i> Admin Login';
    adminButton.onclick = isAdminMode ? showAdminPanel : showAdminLogin;
    
    document.body.appendChild(adminButton);
}

function showAdminLogin() {
    const token = prompt('Enter admin token:');
    if (token) {
        adminToken = token;
        localStorage.setItem('admin_token', token);
        verifyAdminToken();
    }
}

async function verifyAdminToken() {
    if (!adminToken) return;
    
    try {
        const response = await fetch('/admin/status', {
            headers: {
                'Authorization': `Bearer ${adminToken}`
            }
        });
        
        if (response.ok) {
            isAdminMode = true;
            console.log('Admin authentication successful');
            updateAdminUI();
        } else {
            isAdminMode = false;
            adminToken = null;
            localStorage.removeItem('admin_token');
            console.log('Admin authentication failed');
            updateAdminUI();
        }
    } catch (error) {
        console.error('Error verifying admin token:', error);
        isAdminMode = false;
        adminToken = null;
        localStorage.removeItem('admin_token');
        updateAdminUI();
    }
}

function updateAdminUI() {
    const adminButton = document.getElementById('admin-login-btn');
    if (adminButton) {
        adminButton.innerHTML = isAdminMode ? '<i class="fas fa-user-shield mr-1"></i> Admin' : '<i class="fas fa-key mr-1"></i> Admin Login';
        adminButton.onclick = isAdminMode ? showAdminPanel : showAdminLogin;
    }
    
    // Update package cards with admin buttons
    if (isAdminMode && document.getElementById('packages-grid')) {
        addAdminButtonsToPackages();
    }
}

function initializeAdminPanel() {
    if (!isAdminMode) return;
    
    // Add admin control panel
    const adminPanel = document.createElement('div');
    adminPanel.id = 'admin-panel';
    adminPanel.className = 'fixed top-32 right-4 z-40 bg-white border border-gray-300 rounded-lg shadow-lg p-4 w-64';
    adminPanel.style.display = 'none';
    adminPanel.innerHTML = `
        <h3 class="text-lg font-bold mb-3 text-gray-900">Admin Panel</h3>
        <div class="space-y-2">
            <button onclick="triggerAllBuildsCheck()" class="w-full px-3 py-2 bg-blue-600 text-white rounded hover:bg-blue-700 transition-colors text-sm">
                <i class="fas fa-search mr-2"></i>Check Stalled Builds
            </button>
            <button onclick="showSystemStatus()" class="w-full px-3 py-2 bg-green-600 text-white rounded hover:bg-green-700 transition-colors text-sm">
                <i class="fas fa-info-circle mr-2"></i>System Status
            </button>
            <button onclick="logoutAdmin()" class="w-full px-3 py-2 bg-red-600 text-white rounded hover:bg-red-700 transition-colors text-sm">
                <i class="fas fa-sign-out-alt mr-2"></i>Logout
            </button>
        </div>
    `;
    
    document.body.appendChild(adminPanel);
}

function showAdminPanel() {
    const panel = document.getElementById('admin-panel');
    if (panel) {
        panel.style.display = panel.style.display === 'none' ? 'block' : 'none';
    }
}

function addAdminButtonsToPackages() {
    const packageCards = document.querySelectorAll('[data-name]');
    packageCards.forEach(card => {
        const packageName = card.getAttribute('data-name');
        const actionsDiv = card.querySelector('.p-6.flex.gap-3');
        
        if (actionsDiv && !actionsDiv.querySelector('.admin-trigger-btn')) {
            const triggerBtn = document.createElement('button');
            triggerBtn.className = 'admin-trigger-btn px-3 py-2 bg-purple-600 text-white rounded-lg hover:bg-purple-700 transition-colors text-sm font-medium';
            triggerBtn.innerHTML = '<i class="fas fa-hammer mr-1"></i>Trigger Build';
            triggerBtn.onclick = () => triggerPackageBuild(packageName);
            
            actionsDiv.appendChild(triggerBtn);
        }
    });
}

async function triggerPackageBuild(packageName) {
    if (!adminToken) {
        alert('Admin authentication required');
        return;
    }
    
    const confirmed = confirm(`Trigger build for package "${packageName}"?`);
    if (!confirmed) return;
    
    try {
        const response = await fetch('/admin/trigger-build', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
                'Authorization': `Bearer ${adminToken}`
            },
            body: JSON.stringify({
                package_name: packageName
            })
        });
        
        const result = await response.json();
        
        if (response.ok) {
            alert(`Build triggered successfully for ${packageName}`);
            console.log('Build trigger result:', result);
        } else {
            alert(`Failed to trigger build: ${result.error}`);
            console.error('Build trigger error:', result);
        }
    } catch (error) {
        console.error('Error triggering build:', error);
        alert('Failed to trigger build. Please try again.');
    }
}

async function triggerAllBuildsCheck() {
    if (!adminToken) {
        alert('Admin authentication required');
        return;
    }
    
    const confirmed = confirm('Check for stalled builds and restart them?');
    if (!confirmed) return;
    
    try {
        const response = await fetch('/admin/check-builds', {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${adminToken}`
            }
        });
        
        const result = await response.json();
        
        if (response.ok) {
            alert('Build health check completed successfully');
            console.log('Build check result:', result);
        } else {
            alert(`Failed to check builds: ${result.error}`);
            console.error('Build check error:', result);
        }
    } catch (error) {
        console.error('Error checking builds:', error);
        alert('Failed to check builds. Please try again.');
    }
}

async function showSystemStatus() {
    if (!adminToken) {
        alert('Admin authentication required');
        return;
    }
    
    try {
        const response = await fetch('/admin/status', {
            headers: {
                'Authorization': `Bearer ${adminToken}`
            }
        });
        
        const result = await response.json();
        
        if (response.ok) {
            const status = `
System Status:
- Docker Available: ${result.system.docker_available}
- Cron System Running: ${result.system.cron_system_running}
- Runtime Available: ${result.system.runtime_available}

Statistics:
- Total Packages: ${result.statistics.total_packages}
- Successful Builds: ${result.statistics.successful_builds}
- Failed Builds: ${result.statistics.failed_builds}
- Pending Builds: ${result.statistics.pending_builds}
- Total Builds: ${result.statistics.total_builds}
            `;
            alert(status);
            console.log('System status:', result);
        } else {
            alert(`Failed to get system status: ${result.error}`);
            console.error('System status error:', result);
        }
    } catch (error) {
        console.error('Error getting system status:', error);
        alert('Failed to get system status. Please try again.');
    }
}

function logoutAdmin() {
    const confirmed = confirm('Logout from admin mode?');
    if (confirmed) {
        isAdminMode = false;
        adminToken = null;
        localStorage.removeItem('admin_token');
        updateAdminUI();
        
        // Remove admin panel
        const panel = document.getElementById('admin-panel');
        if (panel) {
            panel.remove();
        }
        
        // Remove admin buttons from packages
        document.querySelectorAll('.admin-trigger-btn').forEach(btn => btn.remove());
        
        alert('Logged out from admin mode');
    }
}
