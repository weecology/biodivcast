# Install pacman if it isn't already installed

if ("pacman" %in% rownames(installed.packages()) == FALSE) install.packages("pacman")

# Install analysis packages using pacman

pacman::p_load(dplyr, forecast, ggplot2, Hmisc, tidyr, mgcv, sp, raster,
               maptools, doParallel, stringr, RCurl, roxygen2, rdataretriever,
               broom, devtools, doParallel, dplyr, forecast, ggplot2,
               gimms, Hmisc, maptools, mgcv, prism, raster, stringr, sp,
               tidyr, rgdal, rgeos, DBI, RSQLite, lme4, caret, mapproj,
               viridis, git2r, rstan, readr, purrr, gbm, randomForest,
               purrrlyr, ggjoy
	       )
pacman::p_load_gh('ropensci/rdataretriever')
