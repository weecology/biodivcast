#' @importFrom forecast Arima auto.arima
make_forecast = function(x, fun_name, use_obs_model, settings, ...){
  # `Forecast` functions want NAs for missing years, & want the years in order
  x = complete(x, year = settings$start_yr:settings$last_train_year) %>% 
    arrange(year)
  
  if (use_obs_model) {
    # observer effect will be added back in `make_all_forecasts`
    response_variable = "expected_richness"
  } else {
    response_variable = "richness"
  }
  
  h = settings$end_yr - settings$last_train_year
  
  # Set the `level` so that `upper` and `lower` are 2 sd apart.
  level = pnorm(0.5)
  
  if (all(is.na(x[[response_variable]]))) {
    warning("Empty response variable")
    return(list(NA))
  }
  
  if (fun_name == "naive") {
    # `forecast::naive` refuses to predict when the final observation is NA.
    # But we can fit the same model with `Arima(order = c(0,1,0))`
    fun = purrr::partial(Arima, order = c(0, 1, 0))
  } else {
    # Just get the named function
    fun = purrr::partial(getFromNamespace(fun_name, "forecast"), 
                         seasonal = FALSE)
  }
  
  model = fun(y = x[[response_variable]], ...)
  fcst = forecast::forecast(model, h = h, level = level)
  
  if (any(is.na(fcst$mean))) {
    warning("NA in predictions")
    return(list(NA))
  }
  
  coef_names = if (length(coef(model)) > 0) {
    list(names(coef(model)))
  } else {
    list(NA)
  }
  
  # Distance between `upper` and `lower` is 2 sd, so divide by 2
  data_frame(year = seq(settings$last_train_year + 1, settings$end_yr), 
         mean = c(fcst$mean), sd = c(fcst$upper - fcst$lower) / 2, 
         model = fun_name, use_obs_model = use_obs_model,
         coef_names = coef_names)
}

make_all_forecasts = function(x, fun_name, use_obs_model, 
                              settings, observer_sigmas, ...){
  forecast_data = x %>% 
    filter(year <= settings$last_train_year) %>% 
    group_by(site_id, iteration)
  
  if (!use_obs_model) {
    # Without an observation model, all the iterations will be the same.
    # Don't bother fitting the same model to each iteration
    forecast_data = filter(forecast_data, iteration == 1)
  }
  
  out = purrrlyr::by_slice(forecast_data, make_forecast, fun_name = fun_name, 
                 use_obs_model = use_obs_model, settings = settings, ...,
                 .collate = "row") %>%
    left_join(select(x_richness, -sd), c("site_id", "year", "iteration"))
  
  if (use_obs_model) {
    if (settings$timeframe == "future") {
      # Calculate random observer effects
      out$observer_effect = rnorm(nrow(out), 
                                  sd = observer_sigmas[out$iteration])
    }
    # Observer effect was subtraced out in make_forcast. Add it back in here.
    out = mutate(out, mean = mean + observer_effect)
  }
  
  select(out, site_id, year, mean, sd, iteration, richness, model, 
         use_obs_model, coef_names)
}

make_test_set = function(x, future, observer_sigmas, settings){
  if (settings$timeframe == "future") {
    obs_sd = unique(x$observer_sigma)
    test = mutate(future, 
                  observer_effect = !!rnorm(nrow(future), sd = obs_sd),
                  richness = NA)
  } else{
    test = filter(x, year > !!settings$last_train_year)
  }
  
  test
}

make_gbm_predictions = function(x, use_obs_model, settings, future,
                                observer_sigmas) {
  train = filter(x, year <= settings$last_train_year)
  test = make_test_set(x, future, observer_sigmas, settings)
  
  if (use_obs_model) {
    train$y = train$expected_richness
  } else {
    train$y = train$richness
  }
  
  formula = paste("y ~", paste(settings$vars, collapse = " + "))
  
  g = gbm::gbm(as.formula(formula), 
               data = train,
               distribution = "gaussian",
               interaction.depth = 5,
               shrinkage = .015,
               n.trees = 1E4)
  
  n.trees = gbm::gbm.perf(g, plot.it = FALSE)
  
  # sd of training set residuals
  sd = sqrt(mean((predict(g, n.trees = n.trees) - train$y)^2))
  
  mean = predict(g, test, n.trees = n.trees)
  if (use_obs_model) {
    mean = mean + test$observer_effect
  }
  
  cbind(test, mean = mean, model = "richness_gbm", 
        stringsAsFactors = FALSE) %>% 
    select(site_id, year, mean, richness, model) %>% 
    mutate(sd = !!sd, n.trees = !!n.trees, use_obs_model = !!use_obs_model)
}


combine_predictions = function(x){
  # If we only have one iteration, we want to say the variance is zero, not that
  # it's NA.
  safe_var = function(x){
    if (length(x) == 1) {
      0
    } else {
      var(x)
    }
  }
  
  # Uncertainty is additive on the variance scale, not the sd scale
  x %>% 
    group_by(site_id, year, model, use_obs_model, richness) %>% 
    summarize(sd = sqrt(mean(safe_var(mean) + mean(sd^2))), 
              mean = mean(mean)) %>% 
    ungroup()
}
