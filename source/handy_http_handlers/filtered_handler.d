/**
 * Defines a "filtered" request handler, that applies an ordered set of filters
 * (otherwise known as a "filter chain") before and after handling a request,
 * as a means of adding a simple middleware layer to HTTP request processing.
 */
module handy_http_handlers.filtered_handler;

import handy_http_primitives;

/**
 * A filter that can be applied to an HTTP request. If the filter determines
 * that it's okay to continue processing the request, it should call
 * `filterChain.doFilter(request, response)` to continue the chain. If the
 * chain is not continued, request processing ends at this filter, and the
 * current response is sent back to the client.
 */
interface HttpRequestFilter {
    void doFilter(ref ServerHttpRequest request, ref ServerHttpResponse response, FilterChain filterChain);
}

/**
 * A filter chain is a singly-linked list that represents a series of filters
 * to be applied when processing a request.
 */
class FilterChain {
    private HttpRequestFilter filter;
    private FilterChain next;

    this(HttpRequestFilter filter, FilterChain next) {
        this.filter = filter;
        this.next = next;
    }

    /**
     * Applies this filter chain link's filter to the given request and
     * response, and then if there's another link in the chain, calls it to
     * apply its filter thereafter, and so on until the chain is complete or
     * a filter has short-circuited without calling `filterChain.doFilter`.
     * Params:
     *   request = The request.
     *   response = The response.
     */
    void doFilter(ref ServerHttpRequest request, ref ServerHttpResponse response) {
        if (next !is null) {
            filter.doFilter(request, response, next);
        }
    }

    /**
     * Builds a filter chain from a list of request filters.
     * Params:
     *   filters = The filters to use to build the filter chain.
     * Returns: The root of the filter chain that when called, executes for
     * each of the filters provided.
     */
    static FilterChain build(HttpRequestFilter[] filters) {
        if (filters.length == 0) return null;
        
        FilterChain root = new FilterChain(filters[0], null);
        FilterChain currentLink = root;
        for (size_t i = 1; i < filters.length; i++) {
            currentLink.next = new FilterChain(filters[i], null);
            currentLink = currentLink.next;
        }
        // Add an "end cap" to the chain to make sure the last filter gets called.
        currentLink.next = new FilterChain(null, null);
        return root;
    }
}

unittest {
    assert(FilterChain.build([]) is null);

    class SimpleFilter : HttpRequestFilter {
        int id;
        bool shortCircuit;
        this(int id, bool shortCircuit = false) {
            this.id = id;
            this.shortCircuit = shortCircuit;
        }

        void doFilter(ref ServerHttpRequest request, ref ServerHttpResponse response, FilterChain filterChain) {
            import std.conv : to;
            response.headers.add("filter-" ~ id.to!string, id.to!string);
            if (!shortCircuit) filterChain.doFilter(request, response);
        }
    }

    // Test that all filters are applied.
    FilterChain fc = FilterChain.build([
        new SimpleFilter(1),
        new SimpleFilter(2),
        new SimpleFilter(3)
    ]);
    ServerHttpRequest request = ServerHttpRequestBuilder().build();
    ServerHttpResponse response = ServerHttpResponseBuilder().build();
    fc.doFilter(request, response);
    assert(response.headers.contains("filter-1"));
    assert(response.headers.contains("filter-2"));
    assert(response.headers.contains("filter-3"));

    // Test that if we short-circuit, any further filters are NOT applied.
    FilterChain fc2 = FilterChain.build([
        new SimpleFilter(1),
        new SimpleFilter(2, true),
        new SimpleFilter(3)
    ]);
    ServerHttpRequest request2 = ServerHttpRequestBuilder().build();
    ServerHttpResponse response2 = ServerHttpResponseBuilder().build();
    fc2.doFilter(request2, response2);
    assert(response2.headers.contains("filter-1"));
    assert(response2.headers.contains("filter-2"));
    assert(!response2.headers.contains("filter-3"));
}

/**
 * A simple base filter that should always sit at the bottom of the filter
 * chain, which just calls a request handler.
 */
class BaseHandlerRequestFilter : HttpRequestFilter {
    /// The request handler that'll be called.
    private HttpRequestHandler handler;

    this(HttpRequestHandler handler) {
        this.handler = handler;
    }

    void doFilter(ref ServerHttpRequest request, ref ServerHttpResponse response, FilterChain filterChain) {
        handler.handle(request, response);
        // Don't call filterChain.doFilter because this is always the last part of the filter chain.
    }
}

/**
 * The FilteredHandler is a request handler you can add to your server to apply
 * a filter chain to an underlying request handler.
 */
class FilteredHandler : HttpRequestHandler {
    /// The internal filter chain that this handler calls.
    private FilterChain filterChain;

    /**
     * Constructs a filtered handler that applies the given filter chain. Note
     * that you should probabconstly use the other constructor for most cases, but
     * if you really want to provide a custom filter chain, you'll most likely
     * want to add the `BaseHandlerRequestFilter` as the last one in the chain.
     * Params:
     *   filterChain = The filter chain to use.
     */
    this(FilterChain filterChain) {
        this.filterChain = filterChain;
    }

    /**
     * Constructs a filtered handler that applies the given set of filters, in
     * order, before potentially calling the given base handler.
     * Params:
     *   filters = The set of filters to apply to all requests.
     *   baseHandler = The base handler that'll be called if an incoming
     *                 request is passed successfully through all filters.
     */
    this(HttpRequestFilter[] filters, HttpRequestHandler baseHandler) {
        HttpRequestFilter[] allFilters = filters ~ [cast(HttpRequestFilter) new BaseHandlerRequestFilter(baseHandler)];
        this.filterChain = FilterChain.build(allFilters);
    }

    /**
     * Handles an incoming request by simply calling the filter chain on it.
     * Params:
     *   request = The request.
     *   response = The response.
     */
    void handle(ref ServerHttpRequest request, ref ServerHttpResponse response) {
        filterChain.doFilter(request, response);
    }
}
