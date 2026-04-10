import { LightningElement, api, track } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import askQuestion from '@salesforce/apex/AiSalesAssistantController.askQuestion';
import getCurrentUserInfo from '@salesforce/apex/AiSalesAssistantController.getCurrentUserInfo';
import getMyDayEligibility from '@salesforce/apex/AiSalesAssistantController.getMyDayEligibility';
import getMyDayBrief from '@salesforce/apex/AiSalesAssistantController.getMyDayBrief';
import CHARTJS from '@salesforce/resourceUrl/ChartJsLib';

export default class AskSalesforce extends LightningElement {
    @api chatTitle = 'Ask Salesforce';
    @api placeholderText = 'Ask about pipeline, deals, leads, cases...';

    @track messages = [];
    @track userInput = '';
    @track isLoading = false;
    @track currentUserFirstName = '';
    @track showMyDayChip = false;

    messageIdCounter = 0;
    conversationHistory = [];
    chartJsLoaded = false;
    chartInstances = new Map(); // msgId -> Chart instance
    renderedChartIds = new Set(); // track which message charts have been rendered

    get showWelcome() {
        return this.messages.length === 0 && !this.isLoading;
    }

    get welcomeGreeting() {
        const hour = new Date().getHours();
        const greeting = hour < 12 ? 'Good morning' : hour < 17 ? 'Good afternoon' : 'Good evening';
        return this.currentUserFirstName
            ? `${greeting}, ${this.currentUserFirstName}! 👋`
            : `${greeting}! 👋`;
    }

    get isSendDisabled() {
        return this.isLoading || !this.userInput || !this.userInput.trim();
    }

    // --- Lifecycle Hooks ---

    connectedCallback() {
        // Polyfill ResizeObserver if missing (Salesforce Locker Service blocks it)
        if (typeof window.ResizeObserver === 'undefined') {
            window.ResizeObserver = class ResizeObserver {
                constructor() { this._cb = null; }
                observe() {}
                unobserve() {}
                disconnect() {}
            };
        }
        // Guard: loadScript crashes if the resource URL is null (e.g. cache miss after deploy)
        if (CHARTJS) {
            loadScript(this, CHARTJS)
                .then(() => {
                    this.chartJsLoaded = true;
                })
                .catch(error => {
                    console.error('Failed to load Chart.js:', error);
                });
        }
        // Fetch logged-in user info for personalized greeting
        getCurrentUserInfo()
            .then(result => {
                if (result && result.userName) {
                    // Extract first name from full name (e.g. "Sumeet Lamba" → "Sumeet")
                    this.currentUserFirstName = result.userName.split(' ')[0];
                }
            })
            .catch(error => {
                console.error('Failed to fetch user info:', error);
            });

        // Check if user is eligible for My Day briefing (AD/CSM profiles only)
        getMyDayEligibility()
            .then(result => {
                if (result && result.eligible === 'true') {
                    this.showMyDayChip = true;
                }
            })
            .catch(error => {
                console.error('Failed to check My Day eligibility:', error);
            });
    }

    renderedCallback() {
        // Render any charts that have config but haven't been drawn yet
        this.messages.forEach(msg => {
            if (msg.hasChart && !this.renderedChartIds.has(msg.id)) {
                const canvas = this.template.querySelector(`canvas[data-msg-id="${msg.id}"]`);
                if (canvas) {
                    this.renderedChartIds.add(msg.id);
                    try {
                        this.renderChart(canvas, msg.chartConfig, msg.id);
                    } catch (e) {
                        console.error('Chart render failed for msg ' + msg.id + ':', e);
                    }
                }
            }
        });
    }

    disconnectedCallback() {
        // Clean up all chart instances to prevent memory leaks
        this.chartInstances.forEach(chart => chart.destroy());
        this.chartInstances.clear();
    }

    // --- Event Handlers ---

    handleInputChange(event) {
        this.userInput = event.target.value;
    }

    handleKeyUp(event) {
        if (event.key === 'Enter' && !this.isSendDisabled) {
            this.handleSend();
        }
    }

    handleSuggestion(event) {
        const question = event.currentTarget.dataset.question;
        this.userInput = question;
        this.handleSend();
    }

    handleMyDay() {
        // Add user message
        this.addUserMessage('⚡ My Day — Daily Priority Briefing');
        this.isLoading = true;

        getMyDayBrief()
            .then(result => {
                if (result.success) {
                    this.addAssistantMessage(
                        result.answer,
                        result.soqlQuery,
                        result.recordCount,
                        result.executionTimeMs
                    );
                } else {
                    this.addErrorMessage(result.errorMessage || 'Unable to generate your daily briefing. Please try again.');
                }
            })
            .catch(error => {
                const msg = error.body ? error.body.message : 'An unexpected error occurred generating your daily briefing.';
                this.addErrorMessage(msg);
            })
            .finally(() => {
                this.isLoading = false;
                this.scrollToBottom();
            });
    }

    handleSend() {
        const question = this.userInput.trim();
        if (!question) return;

        // Add user message
        this.addUserMessage(question);
        this.userInput = '';
        this.isLoading = true;

        // Build full conversation history for session memory
        const context = this.conversationHistory.length > 0
            ? this.conversationHistory
                  .map((h, i) => `Q${i + 1}: ${h.question}\nA${i + 1}: ${h.answer}`)
                  .join('\n---\n')
            : '';

        // Call Apex
        askQuestion({ userQuestion: question, conversationContext: context })
            .then(result => {
                if (result.success) {
                    this.addAssistantMessage(
                        result.answer,
                        result.soqlQuery,
                        result.recordCount,
                        result.executionTimeMs
                    );
                    // Add to session history (truncate answer to 500 chars, keep last 10 exchanges)
                    this.conversationHistory.push({
                        question: question,
                        answer: result.answer ? result.answer.substring(0, 500) : ''
                    });
                    if (this.conversationHistory.length > 10) {
                        this.conversationHistory.shift();
                    }
                } else {
                    this.addErrorMessage(result.errorMessage);
                    // Don't clear history on error — previous successful Q&As remain valid context
                }
            })
            .catch(error => {
                const msg = error.body ? error.body.message : 'An unexpected error occurred. Please try again.';
                this.addErrorMessage(msg);
            })
            .finally(() => {
                this.isLoading = false;
                this.scrollToBottom();
            });
    }

    handleSoqlToggle(event) {
        const msgId = parseInt(event.currentTarget.dataset.msgId, 10);
        this.messages = this.messages.map(msg => {
            if (msg.id === msgId) {
                return {
                    ...msg,
                    showSoql: !msg.showSoql,
                    soqlToggleLabel: msg.showSoql ? 'Show SOQL' : 'Hide SOQL'
                };
            }
            return msg;
        });
    }

    // --- Message Builders ---

    addUserMessage(text) {
        const msg = this.createBaseMessage(text);
        msg.isUser = true;
        msg.isAssistant = false;
        msg.isError = false;
        msg.containerClass = 'message-row user';
        msg.bubbleClass = 'message-bubble user';
        this.messages = [...this.messages, msg];
        this.scrollToBottom();
    }

    addAssistantMessage(text, soqlQuery, recordCount, executionTimeMs) {
        const safeText = text || '';
        const msg = this.createBaseMessage(safeText);
        msg.isUser = false;
        msg.isAssistant = true;
        msg.isError = false;
        msg.containerClass = 'message-row assistant';
        msg.bubbleClass = 'message-bubble assistant';

        // Extract chart config from response text (if present)
        const { cleanText, chartConfig } = this.extractChartConfig(safeText);

        // Format the text - convert markdown-like formatting to HTML
        msg.formattedText = this.formatResponse(cleanText);

        // Chart data
        msg.chartConfig = chartConfig;
        msg.hasChart = chartConfig !== null && this.chartJsLoaded;
        msg.chartRendered = false;

        // SOQL
        msg.soqlQuery = soqlQuery;
        msg.showSoql = false;
        msg.soqlToggleLabel = 'Show SOQL';

        // Metadata
        msg.recordCount = recordCount;
        msg.recordCountLabel = recordCount !== null && recordCount !== undefined
            ? recordCount + ' record' + (recordCount !== 1 ? 's' : '')
            : null;
        msg.executionTimeLabel = executionTimeMs !== null && executionTimeMs !== undefined
            ? (executionTimeMs / 1000).toFixed(1) + 's'
            : null;

        this.messages = [...this.messages, msg];
        this.scrollToBottom();
    }

    addErrorMessage(text) {
        const msg = this.createBaseMessage(text);
        msg.isUser = false;
        msg.isAssistant = false;
        msg.isError = true;
        msg.containerClass = 'message-row assistant';
        msg.bubbleClass = 'message-bubble error';
        this.messages = [...this.messages, msg];
        this.scrollToBottom();
    }

    createBaseMessage(text) {
        const now = new Date();
        return {
            id: this.messageIdCounter++,
            text: text,
            timestamp: now.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
        };
    }

    // --- Chart Extraction & Rendering ---

    extractChartConfig(text) {
        if (!text) return { cleanText: '', chartConfig: null };

        // Try multiple patterns to handle LLM formatting variations
        const patterns = [
            /```chartConfig\s*\n([\s\S]*?)\n\s*```\s*$/,        // Standard: newlines around JSON
            /```chartConfig\s*\r?\n?([\s\S]*?)\r?\n?\s*```\s*$/, // Flexible newlines
            /```chartConfig\s+([\s\S]*?)\s*```\s*$/,              // Any whitespace separator
            /```chartConfig\s*(\{[\s\S]*\})\s*```\s*$/,           // JSON object directly
        ];

        let match = null;
        let matchedPattern = null;
        for (const pattern of patterns) {
            match = text.match(pattern);
            if (match) {
                matchedPattern = pattern;
                break;
            }
        }

        if (!match) return { cleanText: text, chartConfig: null };

        let chartConfig = null;
        try {
            chartConfig = JSON.parse(match[1].trim());
            // Validate minimum required fields
            if (!chartConfig.type || !chartConfig.labels || !chartConfig.datasets ||
                !Array.isArray(chartConfig.labels) || !Array.isArray(chartConfig.datasets)) {
                chartConfig = null;
            }
        } catch (e) {
            console.warn('Failed to parse chartConfig:', e);
            chartConfig = null;
        }

        // Remove the chartConfig block from the display text
        const cleanText = text.replace(matchedPattern, '').trim();
        return { cleanText, chartConfig };
    }

    renderChart(canvas, config, msgId) {
        // Destroy existing chart on same canvas if any
        if (this.chartInstances.has(msgId)) {
            this.chartInstances.get(msgId).destroy();
            this.chartInstances.delete(msgId);
        }

        // Set explicit canvas dimensions (responsive: false avoids ResizeObserver)
        const container = canvas.parentElement;
        const containerWidth = container ? container.clientWidth - 24 : 700; // minus padding
        const containerHeight = container ? container.clientHeight - 24 : 276;
        canvas.width = containerWidth;
        canvas.height = containerHeight;
        canvas.style.width = containerWidth + 'px';
        canvas.style.height = containerHeight + 'px';

        const ctx = canvas.getContext('2d');

        // Map our chart types to Chart.js types
        const chartType = config.type === 'horizontalBar' ? 'bar'
                        : config.type === 'stackedBar' ? 'bar'
                        : config.type;

        const isHorizontal = config.type === 'horizontalBar';
        const isStacked = config.type === 'stackedBar';

        // SLDS-aligned color palette
        const colors = [
            '#0176d3', '#04844b', '#f38303', '#ba0517', '#7526c3',
            '#00a1e0', '#ff538a', '#76ded9', '#e3a21a', '#2e844a',
            '#5a6872', '#1b5297'
        ];

        const isPieType = config.type === 'pie' || config.type === 'doughnut';
        const backgroundColors = isPieType
            ? colors.slice(0, config.labels.length)
            : undefined;

        const datasets = config.datasets.map((ds, idx) => ({
            label: ds.label,
            data: ds.data,
            backgroundColor: backgroundColors || colors[idx % colors.length],
            borderColor: config.type === 'line' ? colors[idx % colors.length] : undefined,
            borderWidth: config.type === 'line' ? 2 : 1,
            tension: config.type === 'line' ? 0.3 : undefined,
            fill: config.type === 'line' ? false : undefined,
        }));

        // Tooltip value formatter
        const formatValue = (value) => {
            if (config.valueFormat === 'currency' && config.currency === 'INR') {
                if (Math.abs(value) >= 10000000) return '\u20B9' + (value / 10000000).toFixed(2) + ' Cr';
                if (Math.abs(value) >= 100000) return '\u20B9' + (value / 100000).toFixed(2) + ' L';
                return '\u20B9' + value.toLocaleString('en-IN');
            }
            if (config.valueFormat === 'percent') return value + '%';
            if (typeof value === 'number') return value.toLocaleString();
            return value;
        };

        // Axis tick formatter
        const tickCallback = function(value) {
            if (config.valueFormat === 'currency' && config.currency === 'INR') {
                if (Math.abs(value) >= 10000000) return '\u20B9' + (value / 10000000).toFixed(1) + 'Cr';
                if (Math.abs(value) >= 100000) return '\u20B9' + (value / 100000).toFixed(1) + 'L';
                return '\u20B9' + value.toLocaleString('en-IN');
            }
            if (config.valueFormat === 'percent') return value + '%';
            return value.toLocaleString();
        };

        const chartInstance = new window.Chart(ctx, {
            type: chartType,
            data: {
                labels: config.labels,
                datasets: datasets,
            },
            options: {
                indexAxis: isHorizontal ? 'y' : 'x',
                responsive: false,
                maintainAspectRatio: false,
                plugins: {
                    title: {
                        display: !!config.title,
                        text: config.title || '',
                        font: { size: 13, weight: '600' },
                        color: '#032d60',
                        padding: { bottom: 12 },
                    },
                    legend: {
                        display: config.datasets.length > 1 || isPieType,
                        position: isPieType ? 'right' : 'top',
                        labels: {
                            font: { size: 11 },
                            color: '#5a6872',
                            boxWidth: 12,
                        },
                    },
                    tooltip: {
                        callbacks: {
                            label: (tooltipItem) => {
                                const label = tooltipItem.dataset.label || '';
                                const val = formatValue(tooltipItem.raw);
                                return label ? label + ': ' + val : val;
                            },
                        },
                    },
                },
                scales: isPieType ? {} : {
                    x: {
                        stacked: isStacked,
                        title: {
                            display: !!config.xAxisLabel,
                            text: config.xAxisLabel || '',
                            color: '#5a6872',
                            font: { size: 11 },
                        },
                        ticks: { font: { size: 10 }, color: '#5a6872' },
                        grid: { display: false },
                    },
                    y: {
                        stacked: isStacked,
                        title: {
                            display: !!config.yAxisLabel,
                            text: config.yAxisLabel || '',
                            color: '#5a6872',
                            font: { size: 11 },
                        },
                        ticks: {
                            font: { size: 10 },
                            color: '#5a6872',
                            callback: tickCallback,
                        },
                        beginAtZero: true,
                    },
                },
            },
        });

        this.chartInstances.set(msgId, chartInstance);
    }

    // --- Formatting ---

    formatResponse(text) {
        if (!text) return '';

        const lines = text.split('\n');
        const outputParts = [];
        let i = 0;

        while (i < lines.length) {
            // Detect markdown table: line contains | and next lines also contain |
            if (this.isTableRow(lines[i]) && i + 1 < lines.length && this.isTableRow(lines[i + 1])) {
                const tableLines = [];
                while (i < lines.length && this.isTableRow(lines[i])) {
                    tableLines.push(lines[i]);
                    i++;
                }
                outputParts.push(this.buildHtmlTable(tableLines));
            } else {
                outputParts.push(this.formatLine(lines[i]));
                i++;
            }
        }

        return outputParts.join('');
    }

    isTableRow(line) {
        if (!line) return false;
        const trimmed = line.trim();
        return trimmed.startsWith('|') && trimmed.endsWith('|') && trimmed.length > 2;
    }

    buildHtmlTable(tableLines) {
        if (tableLines.length < 2) return tableLines.map(l => this.formatLine(l)).join('');

        const parseRow = (line) =>
            line.trim().split('|').slice(1, -1).map(cell => this.escapeHtml(cell.trim()));

        const headerCells = parseRow(tableLines[0]);

        // Check if second row is separator (---|---|---)
        const isSeparator = /^\|[\s\-:]+(\|[\s\-:]+)+\|$/.test(tableLines[1].trim());
        const dataStart = isSeparator ? 2 : 1;

        let html = '<table style="width:100%;border-collapse:collapse;margin:0.5rem 0;font-size:0.82rem;">';

        // Header
        html += '<thead><tr>';
        for (const cell of headerCells) {
            html += '<th style="background:#f0f3f7;padding:0.4rem 0.6rem;border:1px solid #d8dde6;text-align:left;font-weight:600;color:#032d60;">';
            html += cell.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
            html += '</th>';
        }
        html += '</tr></thead>';

        // Body
        html += '<tbody>';
        for (let r = dataStart; r < tableLines.length; r++) {
            const cells = parseRow(tableLines[r]);
            html += '<tr>';
            for (let c = 0; c < cells.length; c++) {
                const cellContent = (cells[c] || '').replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');
                html += '<td style="padding:0.35rem 0.6rem;border:1px solid #e5e5e5;">' + cellContent + '</td>';
            }
            html += '</tr>';
        }
        html += '</tbody></table>';

        return html;
    }

    formatLine(line) {
        let html = this.escapeHtml(line);

        // Headers: ### -> h4, ## -> h3 (keep them compact in chat)
        if (html.match(/^#{3,}\s+/)) {
            html = '<b>' + html.replace(/^#{3,}\s+/, '') + '</b><br/>';
            return html;
        }
        if (html.match(/^#{2}\s+/)) {
            html = '<br/><b style="font-size:1.05em;">' + html.replace(/^#{2}\s+/, '') + '</b><br/>';
            return html;
        }
        if (html.match(/^#\s+/)) {
            html = '<br/><b style="font-size:1.1em;">' + html.replace(/^#\s+/, '') + '</b><br/>';
            return html;
        }

        // Horizontal rule
        if (/^-{3,}$/.test(html.trim()) || /^\*{3,}$/.test(html.trim())) {
            return '<br/>';
        }

        // Bold
        html = html.replace(/\*\*(.+?)\*\*/g, '<b>$1</b>');

        // Bullet points
        html = html.replace(/^[\-\*]\s+(.+)$/, '&#8226; $1');

        // Numbered lists
        html = html.replace(/^\d+\.\s+(.+)$/, '&#8226; $1');

        return html + '<br/>';
    }

    escapeHtml(text) {
        return text
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;');
    }

    // --- Utilities ---

    scrollToBottom() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const container = this.refs.chatContainer;
            if (container) {
                container.scrollTop = container.scrollHeight;
            }
        }, 100);
    }
}
